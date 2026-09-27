#!/usr/bin/env python3
"""Isolated function tests: never execute the installer entry point or host mutators."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / 'install.sh').read_text()
FUNCTIONS = '\n'.join(re.findall(r'^\w+\(\) \{.*?^\}', SOURCE, re.M | re.S))


class Regression(unittest.TestCase):
    def run_shell(self, body):
        with tempfile.TemporaryDirectory(prefix='reality-test-', dir=os.environ.get('TMPDIR')) as tmp:
            root = Path(tmp)
            for name in ['usr/local/etc/xray', 'usr/local/bin', 'etc/systemd/system', 'proc', 'var/lib']:
                (root / name).mkdir(parents=True)
            functions = FUNCTIONS
            for prefix in ['/usr/local/', '/etc/systemd/', '/etc/logrotate.', '/var/log/', '/var/lib/', '/proc/']:
                functions = functions.replace(prefix, str(root) + prefix)
            prelude = r'''
set -euo pipefail
export TMPDIR="$ROOT"
xray_config_path="$ROOT/usr/local/etc/xray/config.json"
xray_binary_path="$ROOT/usr/local/bin/xray"
xray_binary_backup_path="$xray_binary_path.bak"
link_file="$ROOT/link"
recovery_root="$ROOT/var/lib/xray-vless-reality"
default_shortid=20220701
default_port=443
red= green= yellow= magenta= cyan= none=
uuid=550e8400-e29b-41d4-a716-446655440000
key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
systemctl() { printf '%s\n' "$*" >> "$ROOT/systemctl"; case "$1" in is-active) return 1;; *) return 0;; esac; }
kill() { printf '%s\n' "$*" >> "$ROOT/kill"; return 90; }
chown() { :; }
pkill() { return 90; }
pgrep() { return 1; }
curl() { return 90; }
apt-get() { return 90; }
ss() { return 90; }
netstat() { return 90; }
sleep() { :; }
execute_official_script() { return 90; }
'''
            # Override network/install boundaries after the extracted definitions.
            script = functions + '\n' + prelude + '\n' + body
            result = subprocess.run(['bash', '-c', script], env={**os.environ, 'ROOT': tmp}, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_binary_only_uninstall_skips_official(self):
        self.run_shell(r'''
printf stale > "$xray_binary_path"
read() { printf -v "${!#}" y; }
execute_official_script() { return 81; }
uninstall_xray
[[ ! -e $xray_binary_path ]]
''')

    def test_fresh_failure_before_unit_creation_can_retry(self):
        self.run_shell(r'''
execute_official_script() { return 1; }
systemctl() { case "$1" in stop|is-active) return 1;; show) printf 'not-found\n';; *) return 0;; esac; }
if (run_install 443 "$uuid" old.example); then exit 1; fi
[[ ! -e $recovery_root/pending ]]
if (run_install 443 "$uuid" old.example); then exit 1; fi
[[ ! -e $recovery_root/pending ]]
''')

    def test_update_active_stopped_and_geodata_failure(self):
        self.run_shell(r'''
get_xray_version() { printf '1.0.0'; }
curl() { printf '{"tag_name":"v2.0.0"}'; }
restart_xray() { : > "$ROOT/restarted"; }
for active in true false; do
  for failure in true false; do
    printf '#!/bin/sh\nexit 0\n# old\n' > "$xray_binary_path"
    chmod 751 "$xray_binary_path"
    mkdir -p "$ROOT/usr/local/share/xray" "$ROOT/etc/systemd/system/xray.service.d"
    printf original > "$ROOT/usr/local/share/xray/geoip.dat"
    printf custom > "$ROOT/etc/systemd/system/xray.service.d/custom.conf"
    : > "$ROOT/etc/systemd/system/xray.service"
    rm -f "$ROOT/restarted"
    systemctl() { [[ $1 != is-active || $active == true ]]; }
    execute_official_script() {
      if [[ $1 == install ]]; then
        [[ $* == *--no-update-service* ]] || return 1
        printf '#!/bin/sh\nexit 0\n# new\n' > "$xray_binary_path"
      else
        printf changed > "$ROOT/usr/local/share/xray/geoip.dat"
        [[ $failure != true ]] || return 1
      fi
    }
    status=0; (update_xray) || status=$?
    if [[ $failure == true ]]; then
      [[ $status != 0 && $(< "$xray_binary_path") == *'# old'* ]]
      [[ $(< "$ROOT/usr/local/share/xray/geoip.dat") == original ]]
      [[ $(stat -c %a "$xray_binary_path") == 751 ]]
    else
      [[ $status == 0 && $(< "$xray_binary_path") == *'# new'* ]]
    fi
    [[ $(< "$ROOT/etc/systemd/system/xray.service.d/custom.conf") == custom ]]
    if [[ $active == true ]]; then [[ -f $ROOT/restarted ]]; else [[ ! -e $ROOT/restarted ]]; fi
    [[ ! -e $recovery_root/pending ]]
  done
done
''')

    def test_ipv6_link_rejects_ipv4_only_listen(self):
        if not os.environ.get('XRAY_TEST_BINARY'):
            self.skipTest('set XRAY_TEST_BINARY to a verified official core')
        self.run_shell(r'''
ln -s "$XRAY_TEST_BINARY" "$xray_binary_path"
keys=$("$xray_binary_path" x25519)
private=$(awk '/PrivateKey:/ {print $2}' <<< "$keys")
public=$(awk '/^Password/ {print $NF}' <<< "$keys")
write_config 443 "$uuid" old.example "$private" "$public"
get_public_ip() { printf '2001:db8::1\n'; }
if (view_subscription_info); then exit 1; fi
[[ ! -e $link_file ]]
''')

    def test_reinstall_rollback_restores_config_backup(self):
        self.run_shell(r'''
write_config 443 "$uuid" old.example "$key" "$key"
printf previous-backup > "${xray_config_path}.bak"
printf old-core > "$xray_binary_path"
: > "$ROOT/etc/systemd/system/xray.service"
execute_official_script() {
    printf overwritten > "${xray_config_path}.bak"
    return 1
}
if (run_install 443 "$uuid" old.example); then exit 1; fi
[[ $(< "${xray_config_path}.bak") == previous-backup ]]
''')

    def test_real_core_config_and_ipv6_link(self):
        if not os.environ.get('XRAY_TEST_BINARY'):
            self.skipTest('set XRAY_TEST_BINARY to a verified official core')
        self.run_shell(r'''
ln -s "$XRAY_TEST_BINARY" "$xray_binary_path"
keys=$("$xray_binary_path" x25519)
private=$(awk '/PrivateKey:/ {print $2}' <<< "$keys")
public=$(awk '/^Password/ {print $NF}' <<< "$keys")
mkdir -p "$ROOT/proc/sys/net/ipv6/conf/all" "$ROOT/proc/net"
printf 0 > "$ROOT/proc/sys/net/ipv6/conf/all/disable_ipv6"
: > "$ROOT/proc/net/if_inet6"
write_config 443 "$uuid" old.example "$private" "$public"
"$xray_binary_path" run -test -config "$xray_config_path"
jq '.inbounds[0].streamSettings.realitySettings.target="old.example:443"' "$xray_config_path" > "$ROOT/config"
mv "$ROOT/config" "$xray_config_path"
write_config 8443 "$uuid" new.example "$private" "$public" modify
"$xray_binary_path" run -test -config "$xray_config_path"
get_public_ip() { printf '2001:db8::1\n'; }
view_subscription_info
[[ $(< "$link_file") == *'@[2001:db8::1]:8443?'* ]]
[[ $(stat -c %a "$link_file") == 600 ]]
''')

    def test_precheck_installs_process_dependency(self):
        self.run_shell(r'''
check_system_compatibility() { :; }
id() { [[ $* != -u ]] || { printf 0; return; }; command id "$@"; }
command() {
    if [[ $* == '-v pgrep' && ! -e $ROOT/procps ]]; then return 1; fi
    builtin command "$@"
}
apt-get() { printf '%s\n' "$*" >> "$ROOT/apt"; : > "$ROOT/procps"; }
(pre_check) || exit 1
[[ -e $ROOT/procps ]]
[[ $(< "$ROOT/apt") == *procps* ]]
''')

    def test_restore_checks_residual_process_before_deletion(self):
        self.run_shell(r'''
printf original > "$xray_binary_path"
chmod 751 "$xray_binary_path"
backup_paths=("$xray_binary_path")
backup_state
printf changed > "$xray_binary_path"
mkdir -p "$ROOT/proc/123"
ln -s "$xray_binary_path" "$ROOT/proc/123/exe"
pgrep() { printf '123\n'; }
if (rollback_binary_and_service); then exit 1; fi
[[ $(< "$xray_binary_path") == changed ]]
kill() { rm -rf "$ROOT/proc/123"; }
(rollback_binary_and_service) || exit 1
[[ $(< "$xray_binary_path") == original ]]
[[ $(stat -c %a "$xray_binary_path") == 751 ]]
''')

    def test_modify_failed_restore_keeps_original_baseline(self):
        self.run_shell(r'''
write_config 443 "$uuid" old.example "$key" "$key"
ask_port() { printf 8443; }
ask_uuid() { printf '550e8400-e29b-41d4-a716-446655440000'; }
ask_domain() { printf new.example; }
restart_xray() { return 1; }
systemctl() { return 1; }
if (modify_config); then exit 1; fi
[[ -d $recovery_root/pending ]]
jq -e '.inbounds[0].port==443' "$recovery_root/pending/0"
if (modify_config); then exit 1; fi
jq -e '.inbounds[0].port==443' "$recovery_root/pending/0"
''')

    def test_recovery_failure_blocks_new_baseline(self):
        self.run_shell(r'''
printf original > "$xray_binary_path"
backup_paths=("$xray_binary_path")
backup_state
saved=$backup_dir
printf changed > "$xray_binary_path"
systemctl() { return 1; }
if rollback_binary_and_service; then exit 1; fi
unset backup_dir
if backup_state; then exit 1; fi
[[ $(< "$saved/0") == original ]]
if (uninstall_xray <<<''); then exit 1; fi
[[ $(< "$xray_binary_path") == changed ]]
''')

    def test_partial_service_install_refused_before_mutation(self):
        self.run_shell(r'''
mkdir -p "$ROOT/etc/systemd/system/xray.service.d"
printf custom > "$ROOT/etc/systemd/system/xray.service.d/custom.conf"
execute_official_script() { : > "$ROOT/installer-called"; return 1; }
if (run_install 443 "$uuid" old.example); then exit 1; fi
[[ ! -e $ROOT/installer-called ]]
[[ $(< "$ROOT/etc/systemd/system/xray.service.d/custom.conf") == custom ]]
''')

    def test_fresh_rollback_closes_dropins_and_retry(self):
        self.run_shell(r'''
execute_official_script() {
    mkdir -p "$ROOT/etc/systemd/system/xray.service.d" "$ROOT/etc/systemd/system/xray@.service.d"
    : > "$ROOT/etc/systemd/system/xray.service"
    : > "$ROOT/etc/systemd/system/xray@.service"
    : > "$xray_binary_path"
    return 1
}
for attempt in 1 2; do
    if (run_install 443 "$uuid" old.example); then exit 1; fi
    [[ ! -e $xray_binary_path && ! -e $ROOT/etc/systemd/system/xray.service.d && ! -e $ROOT/etc/systemd/system/xray@.service.d ]]
done
''')

    def test_restart_requires_stable_managed_pid(self):
        self.run_shell(r'''
: > "$xray_binary_path"
: > "$ROOT/etc/systemd/system/xray.service"
mkdir -p "$ROOT/proc/123" "$ROOT/proc/124"
ln -s "$xray_binary_path" "$ROOT/proc/123/exe"
ln -s /unrelated/xray "$ROOT/proc/124/exe"
for mode in changing wrong dead stable; do
    printf 0 > "$ROOT/count"
    systemctl() {
        case "$1" in
            is-active) [[ $mode != dead || $(< "$ROOT/count") -lt 2 ]];;
            show)
                n=$(< "$ROOT/count"); printf '%s' "$((n+1))" > "$ROOT/count"
                case $mode in changing) printf '%s\n' "$((123+n))";; wrong) printf '124\n';; *) printf '123\n';; esac ;;
            *) return 0;;
        esac
    }
    status=0; (restart_xray) || status=$?
    if [[ $mode == stable ]]; then [[ $status == 0 && $(< "$ROOT/count") -ge 3 ]]; else [[ $status != 0 ]]; fi
done
''')

    def test_uninstall_deleted_process_and_query_errors(self):
        self.run_shell(r'''
rm -rf "${xray_config_path%/*}"
mkdir -p "$ROOT/proc/123" "$ROOT/proc/456"
ln -s "$xray_binary_path (deleted)" "$ROOT/proc/123/exe"
ln -s /unrelated/xray "$ROOT/proc/456/exe"
pgrep() { printf '123\n456\n'; }
if (uninstall_xray <<<''); then exit 1; fi
[[ -f $ROOT/kill ]]
[[ $(< "$ROOT/kill") == '-TERM -- 123' ]]
kill() { rm -rf "$ROOT/proc/123"; }
(uninstall_xray <<<'') || exit 1
[[ -L $ROOT/proc/456/exe ]]
pgrep() { return 2; }
mkdir -p "${xray_config_path%/*}"
if (uninstall_xray <<<''); then exit 1; fi
[[ -d ${xray_config_path%/*} ]]
''')

    def test_uninstall_orphan_units_and_dropins(self):
        self.run_shell(r'''
rm -rf "${xray_config_path%/*}"
for residue in xray.service.d xray@.service.d xray@.service; do
    mkdir -p "$ROOT/etc/systemd/system/$residue"
    (uninstall_xray <<<'') || exit 1
    [[ ! -e $ROOT/etc/systemd/system/$residue ]]
done
''')

    def test_port_query_failure_and_fallback(self):
        self.run_shell(r'''
status=0
is_port_in_use 443 || status=$?
[[ $status == 2 ]]
if validate_config_args 443 "$uuid" new.example; then exit 1; fi
if ask_port <<<443; then exit 1; fi
ss() { return 1; }
netstat() { printf 'tcp 0 0 0.0.0.0:443 0.0.0.0:* LISTEN\n'; }
is_port_in_use 443
netstat() { printf 'tcp 0 0 0.0.0.0:8443 0.0.0.0:* LISTEN\n'; }
status=0; is_port_in_use 443 || status=$?; [[ $status == 1 ]]
ss() { :; }
netstat() { return 1; }
status=0; is_port_in_use 443 || status=$?; [[ $status == 1 ]]
ss() { [[ $* == *-ltn* ]] && printf 'LISTEN 0 0 *:443\n'; return 0; }
is_port_in_use 443
''')

    def test_listen_ipv6_enabled_disabled(self):
        self.run_shell(r'''
mkdir -p "$ROOT/proc/sys/net/ipv6/conf/all" "$ROOT/proc/net"
printf 0 > "$ROOT/proc/sys/net/ipv6/conf/all/disable_ipv6"
: > "$ROOT/proc/net/if_inet6"
write_config 443 "$uuid" old.example "$key" "$key"
jq -e '.inbounds[0].listen=="::"' "$xray_config_path"
printf 1 > "$ROOT/proc/sys/net/ipv6/conf/all/disable_ipv6"
rm "$xray_config_path"
write_config 443 "$uuid" old.example "$key" "$key"
jq -e '.inbounds[0].listen=="0.0.0.0"' "$xray_config_path"
rm "$ROOT/proc/net/if_inet6" "$xray_config_path"
write_config 443 "$uuid" old.example "$key" "$key"
jq -e '.inbounds[0].listen=="0.0.0.0"' "$xray_config_path"
''')

    def test_target_alias_and_custom_fields(self):
        self.run_shell(r'''
write_config 443 "$uuid" old.example "$key" "$key"
jq '.inbounds[0].streamSettings.realitySettings.target="old.example:443" | .routing={custom:true} | .inbounds[0].listen="127.0.0.1"' "$xray_config_path" > "$ROOT/config"
mv "$ROOT/config" "$xray_config_path"
(write_config 8443 "$uuid" new.example "$key" "$key" modify) || exit 1
jq -e '.inbounds[0].streamSettings.realitySettings | (.target // .dest)=="new.example:443" and (.dest==null or .dest=="new.example:443")' "$xray_config_path"
jq -e '.routing.custom and .inbounds[0].listen=="127.0.0.1"' "$xray_config_path"
''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
