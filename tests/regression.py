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
    def run_shell(self, body, files=None):
        with tempfile.TemporaryDirectory(prefix='reality-test-', dir=os.environ.get('TMPDIR')) as tmp:
            root = Path(tmp)
            for name, content in (files or {}).items():
                (root / name).write_text(content)
            for name in ['usr/local/etc/xray', 'usr/local/bin', 'etc/systemd/system', 'proc', 'var/lib']:
                (root / name).mkdir(parents=True)
            # The normalizer only matches source text; its literal upstream paths
            # must not be relocated with executable filesystem operations.
            normalizer = re.search(r'^normalize_official_writes\(\) \{.*?^\}', FUNCTIONS, re.M | re.S)
            functions = FUNCTIONS.replace(normalizer.group(), '') if normalizer else FUNCTIONS
            for prefix in ['/usr/local/', '/etc/systemd/', '/etc/logrotate.', '/var/log/', '/var/lib/', '/proc/']:
                functions = functions.replace(prefix, str(root) + prefix)
            if normalizer:
                functions += '\n' + normalizer.group()
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
systemctl() { printf '%s\n' "$*" >> "$ROOT/systemctl"; case "$1" in is-active) return 1;; show) printf 'User=root\n';; *) return 0;; esac; }
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
            script = functions + '\nOFFICIAL_WRAPPER=$(declare -f execute_official_script)\n' + prelude + '\n' + body
            result = subprocess.run(['bash', '-c', script], env={**os.environ, 'ROOT': tmp}, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_precheck_installs_missing_port_probe(self):
        self.run_shell(r'''
check_system_compatibility() { :; }
command() {
    if [[ $* == '-v ss' || $* == '-v netstat' ]]; then
        [[ -e $ROOT/iproute2 ]]; return
    fi
    builtin command "$@"
}
apt-get() { printf '%s\n' "$*" >> "$ROOT/apt"; : > "$ROOT/iproute2"; }
(pre_check) || exit 1
[[ -e $ROOT/iproute2 && $(< "$ROOT/apt") == *iproute2* ]]
''')

    def test_partial_restore_keeps_other_recoverable_files(self):
        self.run_shell(r'''
printf old-core > "$xray_binary_path"
printf old-config > "$xray_config_path"
backup_paths=("$xray_binary_path" "$xray_config_path")
backup_state
printf new-core > "$xray_binary_path"
printf new-config > "$xray_config_path"
was_active=true
restart_xray() { : > "$ROOT/restarted"; }
cp() { [[ $* != *"$backup_dir/0"* ]] || return 1; command cp "$@"; }
if rollback_binary_and_service; then exit 1; fi
[[ $(< "$xray_config_path") == old-config ]]
[[ -d $backup_dir && ! -e $ROOT/restarted ]]
''')

    def test_public_ip_cache_and_network_failure(self):
        self.run_shell(r'''
cache_file="$ROOT/usr/local/etc/xray/.public-ip"
for value in 999.1.1.1 01.2.3.4 1.02.3.4 1.2.003.4 1.2.3.00 2001:::1 ::ffff:192.000.2.1; do
    printf '%s' "$value" > "$cache_file"
    curl() { return 1; }
    if get_public_ip; then exit 1; fi
done
printf '2001:db8::1' > "$cache_file"
[[ $(get_public_ip) == 2001:db8::1 ]]
touch -d '2 days ago' "$cache_file"
curl() { printf 198.51.100.8; }
[[ $(get_public_ip) == 198.51.100.8 && $(< "$cache_file") == 198.51.100.8 ]]
rm -rf "${cache_file%/*}"
[[ $(get_public_ip 2>"$ROOT/stderr") == 198.51.100.8 && ! -s $ROOT/stderr ]]
mkdir -p "$cache_file"
[[ $(get_public_ip 2>"$ROOT/stderr") == 198.51.100.8 && ! -s $ROOT/stderr ]]
curl() { [[ $* != *--ipv4* ]] || return 1; printf '2001:db8::2'; }
[[ $(get_public_ip) == 2001:db8::2 ]]
''')

    def test_fresh_rollback_disables_unit_before_removal(self):
        self.run_shell(r'''
for failure in permanent runtime none; do
    backup_paths=("$xray_binary_path" "$ROOT/etc/systemd/system/xray.service")
    backup_state
    was_active=false
    printf new-core > "$xray_binary_path"
    : > "$ROOT/etc/systemd/system/xray.service"
    systemctl() {
        printf '%s\n' "$*" >> "$ROOT/systemctl"
        if [[ $1 == disable ]]; then
            [[ -f $ROOT/etc/systemd/system/xray.service ]] || return 1
            [[ $failure != permanent && ( $failure != runtime || $* != *--runtime* ) ]] || return 1
        fi
    }
    status=0; (rollback_binary_and_service) || status=$?
    if [[ $failure == none ]]; then
        [[ $status == 0 && ! -e $xray_binary_path && ! -d $backup_dir ]]
    else
        [[ $status != 0 && -e $xray_binary_path && -e $ROOT/etc/systemd/system/xray.service && -d $backup_dir ]]
    fi
    [[ $(< "$ROOT/systemctl") == *disable* ]]
    rm -rf "$backup_dir" "$xray_binary_path" "$ROOT/etc/systemd/system/xray.service" "$ROOT/systemctl"
done
''')

    def test_restore_stop_and_reload_failure_never_restarts(self):
        self.run_shell(r'''
for failure in stop daemon-reload; do
    printf old > "$xray_binary_path"
    backup_paths=("$xray_binary_path")
    backup_state
    was_active=true
    printf new > "$xray_binary_path"
    restart_xray() { : > "$ROOT/restarted"; }
    systemctl() { [[ $1 != "$failure" ]]; }
    if rollback_binary_and_service; then exit 1; fi
    [[ -d $backup_dir && ! -e $ROOT/restarted ]]
    if [[ $failure == stop ]]; then [[ $(< "$xray_binary_path") == new ]];
    else [[ $(< "$xray_binary_path") == old ]]; fi
    rm -rf "$backup_dir"
done
''')

    def test_netstat_only_precheck_skips_package_install(self):
        self.run_shell(r'''
command() {
    [[ $* != '-v ss' ]] || return 1
    builtin command "$@"
}
apt-get() { : > "$ROOT/apt-called"; return 1; }
(pre_check) || exit 1
[[ ! -e $ROOT/apt-called ]]
''')

    def test_missing_port_dependency_install_failure_aborts(self):
        self.run_shell(r'''
check_system_compatibility() { :; }
command() {
    [[ $* != '-v ss' && $* != '-v netstat' ]] || return 1
    builtin command "$@"
}
apt-get() { return 1; }
if (pre_check); then exit 1; fi
''')

    def test_official_installer_write_failure_is_not_success(self):
        self.run_shell(r'''
# Save the reviewed wrapper without invoking any downloaded installer.
eval "${OFFICIAL_WRAPPER/execute_official_script /checked_installer }"
declare -F checked_installer >/dev/null
xray_install_script_url=https://fixture.invalid/script
cat > "$ROOT/official-fixture" <<'FIXTURE'
# Inert fixture with all six required pinned-source anchors.
TMP_DIRECTORY=unused NAME=xray dir_tmp=unused file_dlc=dlc.dat file_site=geosite.dat file_ip=geoip.dat
install() { [[ ${FAIL_WRITE:-yes} == no ]]; }
install_file() {
    install -m 755 "${TMP_DIRECTORY}/$NAME" "/usr/local/bin/$NAME"
    install -m 644 "${TMP_DIRECTORY}/$NAME" "${DAT_PATH}/$NAME"
}
install_xray() {
  install_file xray
}
install_geodata() {
  [[ $JSON_PATH == "$ROOT/usr/local/etc/xray" && -z $JSONS_PATH && $DAT_PATH == "$ROOT/usr/local/share/xray" ]] || exit 81
  install -d "$DAT_PATH"
  install -m 644 "${dir_tmp}"/${file_dlc} "${DAT_PATH}"/${file_site}
  install -m 644 "${dir_tmp}"/${file_ip} "${DAT_PATH}"/${file_ip}
    printf 'later-success\n'
    exit 0
}
main() {
  if [[ $1 == install-geodata ]]; then install_geodata; fi
  if [[ 0 == 1 ]]; then
    [[ "$XRAY_RUNNING" -eq '1' ]] && start_xray
  else
    :
  fi
}
main "$@"
FIXTURE
export JSON_PATH="$ROOT/foreign-config" JSONS_PATH="$ROOT/foreign-confdir" DAT_PATH="$ROOT/foreign-data"
xray_install_script_sha256=$(sha256sum "$ROOT/official-fixture"); xray_install_script_sha256=${xray_install_script_sha256%% *}
curl() { command cat "$ROOT/official-fixture"; }
if checked_installer install-geodata; then exit 1; fi
# The other wrapper boundaries must reject download/integrity/child failures too.
curl() { printf partial; return 1; }
if checked_installer install-geodata; then exit 1; fi
curl() { command cat "$ROOT/official-fixture"; }
xray_install_script_sha256=invalid
if checked_installer install-geodata; then exit 1; fi
export FAIL_WRITE=no
xray_install_script_sha256=$(sha256sum "$ROOT/official-fixture"); xray_install_script_sha256=${xray_install_script_sha256%% *}
checked_installer install-geodata || exit 1
sed -i 's/exit 0/exit 29/' "$ROOT/official-fixture"
xray_install_script_sha256=$(sha256sum "$ROOT/official-fixture"); xray_install_script_sha256=${xray_install_script_sha256%% *}
if checked_installer install-geodata; then exit 1; fi
''')

    def test_pinned_official_write_guards(self):
        fixture = os.environ.get('XRAY_TEST_OFFICIAL_SCRIPT')
        if not fixture:
            self.skipTest('set XRAY_TEST_OFFICIAL_SCRIPT to the verified pinned source')
        upstream = Path(fixture).read_text()
        # Integrity remains mandatory even for an optional local fixture.
        import hashlib
        match = re.search(r'readonly xray_install_script_sha256="([0-9a-f]+)"', SOURCE)
        assert match is not None
        digest = match.group(1)
        self.assertEqual(hashlib.sha256(Path(fixture).read_bytes()).hexdigest(), digest)
        match = re.search(r'^normalize_official_writes\(\) \{.*?^\}', FUNCTIONS, re.M | re.S)
        assert match is not None
        normalizer = match.group()
        anchors = re.findall(r"^        '(.*)'$", normalizer, re.M)
        self.assertEqual(len(anchors), 6)
        checks = []
        files = {'upstream': upstream}
        for anchor in anchors:
            for altered in (upstream.replace('\n' + anchor + '\n', '\n', 1),
                            upstream.replace('\n' + anchor + '\n', '\n' + (anchor + '\n') * 2, 1)):
                name = f'mismatch-{len(checks)}'
                files[name] = altered
                checks.append(f'if normalize_official_writes "$ROOT/{name}"; then exit 1; fi\n')
        self.run_shell(r'''
normalize_official_writes "$ROOT/upstream"
bash -n "$ROOT/upstream"
if normalize_official_writes "$ROOT/upstream"; then exit 1; fi
# Extract only two reviewed writers; never execute/source the official entrypoint.
python3 -c 'import re,sys; s=open(sys.argv[1]).read(); print("\n".join(re.findall(r"^(?:install_file|install_geodata)\(\) \{.*?^\}", s, re.M|re.S)))' "$ROOT/upstream" > "$ROOT/writers"
eval "$(< "$ROOT/writers")"
TMP_DIRECTORY="$ROOT"; DAT_PATH="$ROOT/data"; PROXY=''; XRAY_IS_INSTALLED_BEFORE_RUNNING_SCRIPT=1
curl() { :; }; sha256sum() { :; }
install() {
    count=$(< "$ROOT/install-count"); count=$((count+1)); printf %s "$count" > "$ROOT/install-count"
    [[ $count != "$fail_at" ]]
}
for name in xray geoip.dat; do
    for fail_at in 0 1; do
        printf 0 > "$ROOT/install-count"
        status=0; (install_file "$name") || status=$?
        [[ $(< "$ROOT/install-count") == 1 ]]
        if [[ $fail_at == 0 ]]; then [[ $status == 0 ]]; else [[ $status != 0 ]]; fi
    done
done
for fail_at in 0 1 2 3; do
    printf 0 > "$ROOT/install-count"
    status=0; (install_geodata) || status=$?
    if [[ $fail_at == 0 ]]; then [[ $status == 0 && $(< "$ROOT/install-count") == 3 ]];
    else [[ $status != 0 && $(< "$ROOT/install-count") == "$fail_at" ]]; fi
done
''' + '\n'.join(checks), files=files)

    def test_new_config_uses_canonical_server_fields(self):
        self.run_shell(r'''
write_config 443 "$uuid" old.example "$key" "$key"
jq -e '.inbounds[0] | .settings.users[0].id=="550e8400-e29b-41d4-a716-446655440000" and
    (.settings | has("clients") | not) and .streamSettings.method=="raw" and
    (.streamSettings | has("network") | not) and
    .streamSettings.realitySettings.target=="old.example:443" and
    (.streamSettings.realitySettings | has("dest") or has("publicKey") or has("password") | not)' "$xray_config_path"
validate_vless_config "$xray_config_path"
''')

    def test_legacy_config_migrates_without_losing_custom_fields(self):
        self.run_shell(r'''
write_config 443 "$uuid" old.example "$key" "$key"
jq --arg key "$key" '
  .routing={custom:true} |
  .inbounds[0].settings |= (.clients=.users | .clients[0].email="keep@example.com" |
    .clients += [{id:"11111111-2222-3333-4444-555555555555",flow:"xtls-rprx-vision"}] |
    .users=[{id:"ignored-by-core"}]) |
  .outbounds[0].settings={domainStrategy:"UseIPv4v6",redirect:"127.0.0.1:80"} |
  .inbounds[0].streamSettings |= (.network="tcp" | .tcpSettings={header:{type:"none"}} | del(.method)) |
  .inbounds[0].streamSettings.realitySettings |=
    (.dest=.target | del(.target) | .publicKey=$key | .custom="keep")' "$xray_config_path" > "$ROOT/legacy"
mv "$ROOT/legacy" "$xray_config_path"
validate_vless_config "$xray_config_path"
ask_port() { printf 8443; }
ask_uuid() { [[ $1 == 550e8400-e29b-41d4-a716-446655440000 ]] || return 1; printf '%s' "$1"; }
ask_domain() { printf '%s' "$1"; }
view_subscription_info() { :; }
(modify_config) || exit 1
validate_vless_config "$xray_config_path"
jq -e '.outbounds[0].streamSettings.sockopt.domainStrategy=="UseIPv4v6" and .outbounds[0].settings.redirect=="127.0.0.1:80" and (.outbounds[0].settings|has("domainStrategy")|not) and .inbounds[0].streamSettings.rawSettings.header.type=="none" and (.inbounds[0].streamSettings|has("tcpSettings")|not)' "$xray_config_path"
jq -e '.routing.custom and (.inbounds[0] |
  .port==8443 and .settings.users[0].email=="keep@example.com" and
  .settings.users[1].id=="11111111-2222-3333-4444-555555555555" and
  (.settings|has("clients")|not) and .streamSettings.method=="raw" and
  (.streamSettings|has("network")|not) and
  .streamSettings.realitySettings.target=="old.example:443" and
  .streamSettings.realitySettings.custom=="keep" and
  (.streamSettings.realitySettings|has("dest") or has("publicKey")|not))' "$xray_config_path"
''')

    def test_modify_stopped_service_does_not_start(self):
        self.run_shell(r'''
write_config 443 "$uuid" old.example "$key" "$key"
ask_port() { printf 8443; }
ask_uuid() { printf '550e8400-e29b-41d4-a716-446655440000'; }
ask_domain() { printf new.example; }
restart_xray() { : > "$ROOT/restarted"; }
view_subscription_info() { :; }
(modify_config) || exit 1
jq -e '.inbounds[0].port==8443' "$xray_config_path"
[[ ! -e $ROOT/restarted && ! -d $recovery_root/pending ]]
''')

    def test_permission_query_failure_does_not_fallback_root(self):
        self.run_shell(r'''
printf original > "$xray_config_path"
chmod 640 "$xray_config_path"
for mode in failed malformed valid; do
    systemctl() {
        case $mode in
            failed) return 1;;
            malformed) printf 'garbage\n';;
            valid) printf 'User=root\n';;
        esac
    }
    status=0; (apply_config_permissions) || status=$?
    if [[ $mode == valid ]]; then [[ $status == 0 && $(stat -c %a "$xray_config_path") == 600 ]];
    else [[ $status != 0 && $(stat -c %a "$xray_config_path") == 640 ]]; fi
done
''')

    def test_invalid_cli_values_do_not_install_dependencies(self):
        self.run_shell(r'''
pre_check() { : > "$ROOT/precheck-called"; }
generate_uuid() { printf '550e8400-e29b-41d4-a716-446655440000'; }
default_sni=old.example
for args in '--port 0' '--uuid invalid' '--sni invalid'; do
    # Only validated fixed test arguments are split here.
    status=0; (main install $args) || status=$?
    [[ $status != 0 && ! -e $ROOT/precheck-called ]]
done
''')

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
systemctl() { [[ $* != *--value* ]] || return 91; case "$1" in stop|is-active) return 1;; show) printf 'LoadState=not-found\n';; *) return 0;; esac; }
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

    def test_real_core_mldsa65_link_export(self):
        if not os.environ.get('XRAY_TEST_BINARY'):
            self.skipTest('set XRAY_TEST_BINARY to a verified official core')
        self.run_shell(r'''
ln -s "$XRAY_TEST_BINARY" "$xray_binary_path"
keys=$("$xray_binary_path" x25519)
private=$(awk '/PrivateKey:/ {print $2}' <<< "$keys")
public=$(awk '/^Password/ {print $NF}' <<< "$keys")
pair=$("$xray_binary_path" mldsa65)
seed=$(awk '/^Seed:/ {print $2}' <<< "$pair")
verify=$(awk '/^Verify:/ {print $2}' <<< "$pair")
write_config 443 "$uuid" old.example "$private" "$public"
jq --arg seed "$seed" '.inbounds[0].streamSettings.realitySettings.mldsa65Seed=$seed' "$xray_config_path" > "$ROOT/config"
mv "$ROOT/config" "$xray_config_path"
get_public_ip() { printf '198.51.100.1\n'; }
view_subscription_info
[[ $(< "$link_file") == *"&pqv=$verify"* ]]
write_config 8443 "$uuid" new.example "$private" "$public" modify
"$xray_binary_path" run -test -config "$xray_config_path"
[[ $(jq -r '.inbounds[0].streamSettings.realitySettings.mldsa65Seed' "$xray_config_path") == "$seed" ]]
# Failed or malformed derivation must not replace the prior link.
printf '%s\n' "$pair" > "$ROOT/pair"
rm "$xray_binary_path"
printf '%s\n' '#!/bin/bash' 'if [[ $1 == mldsa65 ]]; then cat "$ROOT/pair"; exit "${DERIVE_STATUS:-0}"; fi' 'exec "$XRAY_TEST_BINARY" "$@"' > "$xray_binary_path"
chmod +x "$xray_binary_path"
export DERIVE_STATUS=7
printf previous-link > "$link_file"
if view_subscription_info; then exit 1; fi
[[ $(< "$link_file") == previous-link ]]
export DERIVE_STATUS=0
for invalid in short "${verify%?}B"; do
    printf 'Verify: %s\n' "$invalid" > "$ROOT/pair"
    if view_subscription_info; then exit 1; fi
    [[ $(< "$link_file") == previous-link ]]
done
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
jq --arg public "$public" '.inbounds[0].settings |= (.clients=.users | del(.users)) |
    .outbounds[0].settings={domainStrategy:"UseIPv4v6",redirect:"127.0.0.1:80"} |
  .inbounds[0].streamSettings |= (.network="tcp" | .tcpSettings={header:{type:"none"}} | del(.method)) |
    .inbounds[0].streamSettings.realitySettings |= (.dest=.target | del(.target) | .publicKey=$public)' "$xray_config_path" > "$ROOT/config"
mv "$ROOT/config" "$xray_config_path"
validate_vless_config "$xray_config_path"
"$xray_binary_path" run -test -config "$xray_config_path"
get_public_ip() { printf '2001:db8::1\n'; }
view_subscription_info
[[ $(< "$link_file") == *"vless://$uuid@[2001:db8::1]:443?"* && $(< "$link_file") == *"pbk=$public&"* ]]
jq -e '.inbounds[0].settings | has("clients") and (has("users")|not)' "$xray_config_path"
write_config 8443 "$uuid" new.example "$private" "$public" modify
"$xray_binary_path" run -test -config "$xray_config_path"
validate_vless_config "$xray_config_path"
jq -e '.inbounds[0] | .settings.users[0].id!="" and
    .streamSettings.method=="raw" and .streamSettings.realitySettings.target=="new.example:443" and
    (.streamSettings.realitySettings | has("publicKey") or has("dest") | not)' "$xray_config_path"
view_subscription_info
[[ $(< "$link_file") == *'@[2001:db8::1]:8443?'* ]]
[[ $(< "$link_file") == *'type=tcp&'* && $(< "$link_file") == *"pbk=$public&"* ]]
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
systemctl() { case "$1" in is-active) return 0;; show) printf 'User=root\n';; *) return 1;; esac; }
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
        [[ $* != *--value* ]] || return 91
        case "$1" in
            is-active) [[ $mode != dead || $(< "$ROOT/count") -lt 2 ]];;
            show)
                n=$(< "$ROOT/count"); printf '%s' "$((n+1))" > "$ROOT/count"
                case $mode in changing) printf 'MainPID=%s\n' "$((123+n))";; wrong) printf 'MainPID=124\n';; *) printf 'MainPID=123\n';; esac ;;
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
