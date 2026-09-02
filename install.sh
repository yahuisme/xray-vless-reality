#!/bin/bash

# Xray VLESS-Reality 一键安装管理脚本
# 版本: v26.09.02

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="v26.09.02"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://raw.githubusercontent.com/XTLS/Xray-install/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh"
readonly xray_install_script_sha256="7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555"
readonly xray_binary_backup_path="/usr/local/bin/xray.vless-reality.bak"
readonly default_port=443
readonly default_sni="www.sega.com"
readonly default_shortid="20220701"

# --- 颜色定义 ---
readonly red=$'\033[91m' green=$'\033[92m' yellow=$'\033[93m'
readonly magenta=$'\033[95m' cyan=$'\033[96m' none=$'\033[0m'

# --- 全局变量 ---
xray_status_info=""
readonly link_file="/root/xray_vless_reality_link.txt"


# --- 辅助函数 ---
error() {
    printf '\n%b[✖] %s%b\n\n' "$red" "$1" "$none" >&2
    # xray-dual 同款：根据错误内容给出简单建议
    case "$1" in
        *"网络"*|*"下载"*) printf '%b\n' "$yellow提示: 检查网络连接或更换DNS$none" >&2 ;;
        *"权限"*|*"root"*) printf '%b\n' "$yellow提示: 请使用 sudo 运行脚本$none" >&2 ;;
        *"端口"*) printf '%b\n' "$yellow提示: 尝试使用其他端口号$none" >&2 ;;
    esac
}
info() { printf '\n%b[!] %s%b\n' "$yellow" "$1" "$none"; }
success() { printf '\n%b[✔] %s%b\n' "$green" "$1" "$none"; }
warning() { printf '\n%b[⚠] %s%b\n' "$yellow" "$1" "$none"; }

spinner() {
    local pid=$1; local spinstr='|/-\'

    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

is_valid_ipv4() {
    local ip="$1" part
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    local IFS=.
    for part in $ip; do
        ((10#$part <= 255)) || return 1
    done
}

get_public_ip() {
    local ip url cache_file="/usr/local/etc/xray/.public-ip"
    # 缓存 1 天，避免每次查看配置都发起网络请求；公网 IP 变更后自动刷新
    if [[ -f "$cache_file" && -z "$(find "$cache_file" -mmin +1440 2>/dev/null)" ]]; then
        ip=$(<"$cache_file")
        [[ -n "$ip" ]] && { printf '%s\n' "$ip"; return; }
    fi
    for url in https://api.ipify.org https://ip.sb https://checkip.amazonaws.com; do
        if ip=$(curl --fail --silent --show-error --ipv4 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') && is_valid_ipv4 "$ip"; then
            printf '%s\n' "$ip" > "$cache_file" 2>/dev/null || true
            printf '%s\n' "$ip"
            return
        fi
    done
    for url in https://api64.ipify.org https://ip.sb; do
        if ip=$(curl --fail --silent --show-error --ipv6 --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') && [[ "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:* ]]; then
            printf '%s\n' "$ip" > "$cache_file" 2>/dev/null || true
            printf '%s\n' "$ip"
            return
        fi
    done
    error "无法获取公网 IP 地址。" && return 1
}

execute_official_script() {
    local script_file log_file pid result=0
    script_file=$(mktemp)
    log_file=$(mktemp)
    trap 'rm -f -- "${script_file:-}" "${log_file:-}"' RETURN
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 120 "$xray_install_script_url" > "$script_file"; then
        error "下载 Xray 官方安装脚本失败！请检查网络连接。"
        return 1
    fi
    if ! printf '%s  %s\n' "$xray_install_script_sha256" "$script_file" | sha256sum -c --status; then
        error "下载的 Xray 官方安装脚本校验失败，已拒绝执行。"
        return 1
    fi
    bash "$script_file" "$@" >"$log_file" 2>&1 &
    pid=$!
    spinner "$pid"
    wait "$pid" || result=$?
    if (( result != 0 )); then
        error "Xray 官方安装脚本执行失败。"
        sed -n '1,30p' "$log_file" >&2 || true
        return 1
    fi
    trap - RETURN
    rm -f "$script_file" "$log_file"
}

# --- 改进的验证函数 ---
is_valid_port() {
    local port=$1
    # 拒绝前导零（如 0443），避免 jq --argjson 静默改写成 443
    [[ "$port" =~ ^([1-9][0-9]*|0)$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

# 新增：检查端口是否被占用
is_port_in_use() {
    local port=$1 port_in_use=false
    if command -v ss >/dev/null 2>&1; then
        if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q . || \
           ss -H -lun "sport = :$port" 2>/dev/null | grep -q .; then
            port_in_use=true
        fi
    fi
    # ss 不可用或版本过旧（iproute2 < 4.9 无 -H，调用失败）时回退 netstat，避免静默跳过检查
    if [[ "$port_in_use" == false ]] && command -v netstat >/dev/null 2>&1; then
        if netstat -tuln 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" || $4 ~ p" " {found=1} END {exit !found}'; then
            port_in_use=true
        fi
    fi
    if [[ "$port_in_use" == true ]]; then
        return 0
    fi
    return 1
}

# 增强的UUID验证函数
is_valid_uuid() {
    local uuid=$1
    # 标准UUID格式验证：8-4-4-4-12 位十六进制数字
    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

generate_uuid() {
    printf '%s\n' "$(< /proc/sys/kernel/random/uuid)"
}

is_valid_domain() {
    local domain=$1
    [[ "$domain" =~ ^[a-zA-Z0-9.-]{1,253}$ ]] || return 1
    [[ "$domain" != .* && "$domain" != *..* && "$domain" != *. && "$domain" == *.* ]] || return 1
    local label
    IFS='.' read -ra labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
    done
}

url_encode() {
    printf '%s' "$1" | jq -sRr @uri
}

restore_config_backup() {
    local backup="${xray_config_path}.bak"
    [[ -f "$backup" ]] || return 1
    jq empty "$backup" >/dev/null 2>&1 || return 1
    cp -p "$backup" "$xray_config_path" || return 1
    apply_config_permissions || return 1
    # 文件已恢复即视为成功；校验失败只警告，让上层继续尝试重启并向用户报告
    "$xray_binary_path" run -test -config "$xray_config_path" >/dev/null 2>&1 \
        || info "已恢复的配置文件未通过 Xray 校验，请检查 $backup。"
    return 0
}

apply_config_permissions() {
    local config_file=${1:-$xray_config_path} service_user service_group
    service_user=$(systemctl show xray -p User --value 2>/dev/null || true)
    [[ -n "$service_user" && "$service_user" != "-" ]] || service_user=root
    service_group=$(id -g -n "$service_user" 2>/dev/null || true)
    if [[ "$service_user" != root && -n "$service_group" ]] && getent group "$service_group" >/dev/null; then
        chown "root:$service_group" "$config_file"
        chmod 640 "$config_file"
    else
        chown root:root "$config_file"
        chmod 600 "$config_file"
    fi
}

restore_binary_backup() {
    if [[ -f "$xray_binary_backup_path" ]]; then
        cp -p "$xray_binary_backup_path" "$xray_binary_path"
        return 0
    fi
    return 1
}

restore_or_remove_binary() {
    local had_binary=$1
    if [[ "$had_binary" == true ]]; then
        restore_binary_backup
    else
        rm -f "$xray_binary_path"
    fi
}

# 安装失败回滚：恢复/删除二进制，撤销全新安装时官方脚本 enable 的服务，尽量恢复服务状态
rollback_binary_and_service() {
    local had_binary=$1
    restore_or_remove_binary "$had_binary" || true
    [[ "$had_binary" == false ]] && disable_xray_service || true
    [[ -x "$xray_binary_path" ]] && restart_xray || true
}

get_xray_version() {
    local version_output
    version_output=$("$xray_binary_path" version 2>/dev/null || true)
    # 归一化可能的 v 前缀，避免与 GitHub tag 比较时误判
    awk 'NR == 1 {print $2; exit}' <<< "$version_output" | sed 's/^v//'
}

validate_vless_config() {
    local config_file="$1"
    # 外层 // false 保证失败时稳定返回退出码 1（否则 jq 对空结果返回 4）
    jq -e '
        (((.inbounds | type == "array" and length > 0) and
        (.inbounds[0].protocol == "vless") and
        (.inbounds[0].port | type == "number" and . >= 1 and . <= 65535) and
        ((.inbounds[0].settings.clients[0].id // empty) | type == "string" and length > 0) and
        ((.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty) | type == "string" and length > 0) and
        (.inbounds[0].streamSettings.security == "reality") and
        ((.inbounds[0].streamSettings.realitySettings.privateKey // empty) | type == "string" and length > 0) and
        ((.inbounds[0].streamSettings.realitySettings.publicKey // empty) | type == "string" and length > 0) and
        ((.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty) | type == "string" and length > 0)) // false)
    ' "$config_file" >/dev/null 2>&1
}

validate_config_args() {
    local port=$1 uuid=$2 domain=$3 check_port=${4:-true}
    is_valid_port "$port" || return 1
    is_valid_uuid "$uuid" || return 1
    is_valid_domain "$domain" || return 1
    [[ "$check_port" != true ]] || ! is_port_in_use "$port"
}

# --- 改进的系统兼容性检查 ---
check_system_compatibility() {
    # 检查是否为Linux系统
    if [[ "$(uname -s)" != "Linux" ]]; then
        error "错误: 此脚本仅支持 Linux 系统。"
        return 1
    fi

    # 支持的发行版列表
    local supported_distros=("ubuntu" "debian" "kali" "raspbian" "deepin" "mint" "elementary")
    local distro_detected=false distro_name="" distro_version=""

    # 从 /etc/os-release 提取发行版信息（sed 提取，避免 source 泄漏全局变量）
    if [[ -f /etc/os-release ]]; then
        distro_name=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | tr '[:upper:]' '[:lower:]')
        distro_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
        for supported in "${supported_distros[@]}"; do
            if [[ "$distro_name" == "$supported" ]]; then
                distro_detected=true
                break
            fi
        done
        # ID_LIKE 匹配 Debian/Ubuntu 系的派生发行版（如 Linux Mint 的 ID=linuxmint）
        if [[ "$distro_detected" == false ]] && grep -qiE '^ID_LIKE=.*(debian|ubuntu)' /etc/os-release; then
            distro_detected=true
        fi
    fi

    # 兜底：/etc/debian_version 或 APT 包管理器（脚本本就硬依赖 apt 安装依赖）
    if [[ "$distro_detected" == false && -f /etc/debian_version ]]; then
        distro_detected=true
        [[ -z "$distro_name" ]] && distro_name="debian-based"
        [[ -z "$distro_version" ]] && distro_version=$(</etc/debian_version)
    fi
    if [[ "$distro_detected" == false ]] && command -v apt-get &>/dev/null && command -v dpkg &>/dev/null; then
        distro_detected=true
        distro_name="debian-compatible"
        info "检测到基于APT的包管理系统，假定为Debian兼容系统。"
    fi

    if [[ "$distro_detected" == false ]]; then
        error "错误: 未检测到支持的Linux发行版。"
        error "支持的系统: Ubuntu, Debian, Kali Linux, Raspbian, Deepin, Linux Mint, elementary OS"
        error "当前系统信息: $(uname -a)"
        return 1
    fi

    info "系统兼容性检查通过"
    info "检测到系统: ${distro_name:-unknown} ${distro_version:-unknown}"

    # 检查关键命令是否存在
    local required_commands=("systemctl" "awk" "grep" "sed" "ss" "ps" "mktemp" "install" "journalctl" "sha256sum")
    local missing_commands=()
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        error "错误: 缺少必要的系统命令: ${missing_commands[*]}"
        error "请确保系统完整安装后再运行此脚本。"
        return 1
    fi

    return 0
}

# --- 预检查与环境设置 ---
pre_check() {
    [[ $(id -u) != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    
    # 使用改进的系统兼容性检查
    if ! check_system_compatibility; then
        exit 1
    fi

    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        local apt_log
        apt_log=$(mktemp)
        (DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 update && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y jq curl) >"$apt_log" 2>&1 &
        local apt_pid=$!
        spinner "$apt_pid"
        wait "$apt_pid" || true
        if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
            error "依赖 (jq/curl) 自动安装失败。请手动运行 'apt update && apt install -y jq curl' 后重试。"
            sed -n '1,20p' "$apt_log" >&2 || true
            rm -f "$apt_log"
            exit 1
        fi
        rm -f "$apt_log"
        success "依赖已成功安装。"
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" ]]; then xray_status_info="  Xray 状态: ${red}未安装${none}"; return; fi
    local xray_version
    xray_version=$(get_xray_version)
    [[ -n "$xray_version" ]] || xray_version="未知"
    local service_status
    if systemctl is-active --quiet xray 2>/dev/null; then service_status="${green}运行中${none}"; else service_status="${yellow}未运行${none}"; fi
    xray_status_info="  Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

# --- 交互输入助手（current 非空 = 修改已有配置，同名端口豁免占用检查） ---
ask_port() {
    local current=${1:-} port
    while true; do
        if [[ -n "$current" ]]; then
            read -r -p " -> 新端口 (当前: ${cyan}${current}${none}, 回车保留): " port
            [ -z "$port" ] && port=$current
        else
            read -r -p " -> 请输入端口 [1-65535] (默认: ${cyan}${default_port}${none}): " port
            [ -z "$port" ] && port=$default_port
        fi
        if ! is_valid_port "$port"; then
            error "端口无效，请输入一个1-65535之间的数字。"
            continue
        fi
        if [[ -z "$current" || "$port" != "$current" ]] && is_port_in_use "$port"; then
            error "端口 $port 已被占用，请选择其他端口。"
            continue
        fi
        break
    done
    printf '%s' "$port"
}

ask_uuid() {
    local current=${1:-} uuid
    while true; do
        if [[ -n "$current" ]]; then
            read -r -p " -> 新UUID (当前: ${cyan}${current}${none}, 回车保留): " uuid
            [ -z "$uuid" ] && uuid=$current
        else
            read -r -p " -> 请输入UUID (留空将自动生成): " uuid
            if [[ -z "$uuid" ]]; then
                uuid=$(generate_uuid)
                info "已为您生成随机UUID: ${cyan}${uuid}${none}" >&2
                break
            fi
        fi
        if is_valid_uuid "$uuid"; then
            break
        else
            error "UUID格式无效，请输入标准UUID格式 (如: 550e8400-e29b-41d4-a716-446655440000) 或留空自动生成。"
        fi
    done
    printf '%s' "$uuid"
}

ask_domain() {
    local current=${1:-} domain
    while true; do
        if [[ -n "$current" ]]; then
            read -r -p " -> 新SNI域名 (当前: ${cyan}${current}${none}, 回车保留): " domain
            [ -z "$domain" ] && domain=$current
        else
            read -r -p " -> 请输入SNI域名 (默认: ${cyan}${default_sni}${none}): " domain
            [ -z "$domain" ] && domain=$default_sni
        fi
        if is_valid_domain "$domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done
    printf '%s' "$domain"
}

# 全新安装失败时，撤销官方脚本已 enable 的 xray 服务，恢复"未安装"状态
disable_xray_service() {
    systemctl disable --now xray 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
}

# --- 菜单功能函数 ---
install_xray() {
    if [[ -f "$xray_binary_path" ]]; then
        info "检测到 Xray 已安装。继续操作将覆盖现有配置。"
        if ! read -r -p "是否继续？[y/N]: " confirm; then
            info "检测到输入结束，操作已取消。"
            return
        fi
        if [[ ! $confirm =~ ^[yY]$ ]]; then info "操作已取消。"; return; fi
    fi
    info "开始配置 Xray VLESS-Reality..."
    local current_port="" port uuid domain
    # 重装场景：读取现有配置端口，同端口重装时豁免占用检查
    [[ -f "$xray_config_path" ]] && current_port=$(jq -r '.inbounds[0].port // empty' "$xray_config_path" 2>/dev/null || true)
    port=$(ask_port "$current_port")
    uuid=$(ask_uuid)
    domain=$(ask_domain)

    run_install "$port" "$uuid" "$domain"
}

# 更新失败统一回滚：恢复旧核心并尽量重启服务
update_failed() {
    error "$1"
    if restore_or_remove_binary true; then
        restart_xray || true
        error "已恢复更新前的 Xray 核心。"
    fi
    return 1
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法执行更新。请先选择安装选项。" && return; fi
    info "正在检查最新版本..."
    local current_version
    current_version=$(get_xray_version)
    [[ -n "$current_version" ]] || current_version="未知"
    local release_json latest_version
    if ! release_json=$(curl --fail --silent --show-error --location \
        --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest); then
        error "获取最新版本号失败，请检查网络或稍后再试。"
        return
    fi
    latest_version=$(jq -r '.tag_name // empty' <<< "$release_json" | sed 's/^v//')
    if [[ ! "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        error "获取到的最新版本号无效，已停止更新。"
        return
    fi
    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"
    if [[ "$current_version" == "$latest_version" ]]; then success "您的 Xray 已是最新版本，无需更新。" && return; fi
    
    info "发现新版本，开始更新..."
    if ! cp -p "$xray_binary_path" "$xray_binary_backup_path"; then
        error "无法备份当前 Xray 核心，已停止更新。"
        return 1
    fi
    if ! execute_official_script "install" "--without-geodata"; then
        update_failed "Xray 核心更新失败！"
        return
    fi
    if [[ ! -x "$xray_binary_path" ]] || ! "$xray_binary_path" version >/dev/null 2>&1; then
        update_failed "更新后的 Xray 核心无法执行，正在恢复旧版本。"
        return
    fi
    info "正在更新 GeoIP 和 GeoSite 数据文件..."
    if ! execute_official_script "install-geodata"; then
        update_failed "GeoIP/GeoSite 数据更新失败，正在恢复更新前的 Xray 核心。"
        return
    fi

    if ! restart_xray; then
        update_failed "更新后的 Xray 启动失败。"
        return
    fi
    rm -f "$xray_binary_backup_path"
    success "Xray 更新成功！"
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法重启。" && return 1; fi
    info "正在重启 Xray 服务..."
    if ! systemctl restart xray; then
        error "错误: Xray 服务重启失败, 请使用菜单 5 查看日志检查具体原因。"
        return 1
    fi
    sleep 1
    for _ in {1..5}; do
        systemctl is-active --quiet xray && break
        sleep 1
    done
    if ! systemctl is-active --quiet xray; then
        error "错误: Xray 服务启动失败, 请使用菜单 5 查看日志检查具体原因。"
        return 1
    fi
    success "Xray 服务已成功重启！"
}

uninstall_xray() {
    local xray_dir
    xray_dir=$(dirname "$xray_config_path")
    if [[ ! -f "$xray_binary_path" && ! -d "$xray_dir" &&
          ! -f "$xray_binary_backup_path" && ! -f "$link_file" &&
          ! -f /etc/systemd/system/xray.service ]]; then
        info "Xray 未安装，无需卸载。"
        return 0
    fi
    if ! read -r -p "您确定要卸载 Xray 吗？这将删除所有相关文件。[Y/n]: " confirm; then
        info "检测到输入结束，卸载已取消。"
        return
    fi
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        info "卸载操作已取消。"
        return
    fi
    info "正在卸载 Xray..."
    if [[ -f "$xray_binary_path" || -f /etc/systemd/system/xray.service ]]; then
        if ! execute_official_script remove --purge; then
            error "Xray 官方卸载失败！"
            return 1
        fi
    fi
    # Also remove files created by this script and any temporary configs.
    rm -rf -- \
        "$xray_dir" "$xray_binary_backup_path" "$link_file" \
        "${xray_config_path}.tmp."* \
        /usr/local/share/xray /var/log/xray \
        /etc/logrotate.d/xray \
        /etc/systemd/system/xray.service \
        /etc/systemd/system/xray@.service \
        /etc/systemd/system/xray.service.d \
        /etc/systemd/system/xray@.service.d
    systemctl daemon-reload 2>/dev/null || true
    success "Xray 已成功卸载，相关配置、备份、日志和临时文件已清理。"
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法查看日志。" && return; fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

modify_config() {
    if [[ ! -f "$xray_config_path" ]]; then error "错误: Xray 未安装，无法修改配置。" && return; fi
    if ! validate_vless_config "$xray_config_path"; then
        error "当前配置不是有效的 VLESS-Reality 配置，无法修改。"
        return 1
    fi
    info "读取当前配置..."
    local current_port current_uuid current_domain private_key public_key
    current_port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    current_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    current_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$xray_config_path")
    public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path")

    info "请输入新配置，直接回车则保留当前值。"
    local port uuid domain
    port=$(ask_port "$current_port")
    uuid=$(ask_uuid "$current_uuid")
    domain=$(ask_domain "$current_domain")

    if ! write_config "$port" "$uuid" "$domain" "$private_key" "$public_key"; then
        error "配置写入失败，未重启 Xray。"
        return 1
    fi
    if ! restart_xray; then
        warning "新配置未能启动，正在恢复旧配置..."
        if restore_config_backup; then
            restart_xray || true
            error "新配置启动失败，已恢复旧配置。"
        else
            error "旧配置恢复失败，请手动检查 ${xray_config_path}.bak。"
        fi
        return 1
    fi
    success "配置修改成功！"
    view_subscription_info
}

view_subscription_info() {
    if [ ! -f "$xray_config_path" ]; then error "错误: 配置文件不存在, 请先安装。" && return; fi
    if ! validate_vless_config "$xray_config_path"; then
        error "当前配置不是有效的 VLESS-Reality 配置，无法生成订阅链接。"
        return 1
    fi
    
    local ip
    if ! ip=$(get_public_ip); then return 1; fi

    local uuid port domain public_key shortid
    uuid=$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$xray_config_path")
    port=$(jq -r '.inbounds[0].port // empty' "$xray_config_path")
    domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // empty' "$xray_config_path")
    public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey // empty' "$xray_config_path")
    shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$xray_config_path")
    if [[ -z "$public_key" || -z "$shortid" ]]; then
        error "配置文件中缺少公钥或 ShortId 信息，可能是旧版配置，请重新安装以修复。"
        return 1
    fi

    local display_ip="$ip"
    [[ "$ip" == *:* ]] && display_ip="[$ip]"
    local link_name
    link_name="$(hostname) X-reality"
    local link_name_encoded
    link_name_encoded=$(url_encode "$link_name")
    local domain_encoded public_key_encoded shortid_encoded
    domain_encoded=$(url_encode "$domain")
    public_key_encoded=$(url_encode "$public_key")
    shortid_encoded=$(url_encode "$shortid")
    local vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain_encoded}&fp=chrome&pbk=${public_key_encoded}&sid=${shortid_encoded}#${link_name_encoded}"

    umask 077
    printf '%s\n' "$vless_url" > "$link_file"
    chmod 600 "$link_file"
    echo "----------------------------------------------------------------"
    printf '%b\n' "$green --- Xray VLESS-Reality 订阅信息 --- $none"
    printf '%b\n' "$yellow 名称: $cyan$link_name$none"
    printf '%b\n' "$yellow 地址: $cyan$ip$none"
    printf '%b\n' "$yellow 端口: $cyan$port$none"
    printf '%b\n' "$yellow UUID: $cyan$uuid$none"
    printf '%b\n' "$yellow 流控: $cyan xtls-rprx-vision$none"
    printf '%b\n' "$yellow 指纹: $cyan chrome$none"
    printf '%b\n' "$yellow SNI: $cyan$domain$none"
    printf '%b\n' "$yellow 公钥: $cyan$public_key$none"
    printf '%b\n' "$yellow ShortId: $cyan$shortid$none"
        echo "----------------------------------------------------------------"
    printf '%b\n\n%b\n' "$green 订阅链接 (已保存到 $link_file): $none" "$cyan${vless_url}${none}"
        echo "----------------------------------------------------------------"
}

# --- 核心逻辑函数 ---
write_config() {
    local port=$1 uuid=$2 domain=$3 private_key=$4 public_key=$5 shortid=$default_shortid
    local config_content test_log
    config_content=$(jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg domain "$domain" \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg shortid "$shortid" \
    '{"log":{"loglevel":"warning"},"inbounds":[{"listen":"0.0.0.0","port":$port,"protocol":"vless","settings":{"clients":[{"id":$uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":($domain+":443"),"xver":0,"serverNames":[$domain],"privateKey":$private_key,"publicKey":$public_key,"shortIds":[$shortid]}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}}],"outbounds":[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]}')
    if ! printf '%s\n' "$config_content" | jq empty >/dev/null 2>&1; then
        error "生成的 Xray JSON 配置无效。"
        return 1
    fi
    install -d -m 0755 "$(dirname "$xray_config_path")"
    local tmp_config
    tmp_config=$(mktemp "${xray_config_path}.tmp.XXXXXX.json")
    trap 'rm -f -- "${tmp_config:-}"' RETURN
    printf '%s\n' "$config_content" > "$tmp_config"
    test_log=$(mktemp)
    chmod 600 "$test_log"
    if [[ -x "$xray_binary_path" ]] && ! "$xray_binary_path" run -test -config "$tmp_config" >"$test_log" 2>&1; then
        error "Xray 配置校验失败，未替换现有配置。"
        sed -n '1,40p' "$test_log" >&2 || true
        rm -f "$test_log"
        return 1
    fi
    rm -f "$test_log"
    if ! apply_config_permissions "$tmp_config"; then
        error "设置临时配置权限失败，未替换现有配置。"
        return 1
    fi
    if [[ -f "$xray_config_path" ]]; then
        if ! cp -p "$xray_config_path" "${xray_config_path}.bak" ||
           ! chmod 600 "${xray_config_path}.bak"; then
            error "备份现有 Xray 配置失败，未替换现有配置。"
            return 1
        fi
    fi
    if ! mv -f "$tmp_config" "$xray_config_path"; then
        error "替换 Xray 配置失败，现有配置未改变。"
        return 1
    fi
    trap - RETURN
    apply_config_permissions
}

run_install() {
    local port=$1 uuid=$2 domain=$3
    local had_config=false had_binary=false
    [[ -f "$xray_config_path" ]] && had_config=true
    [[ -f "$xray_binary_path" ]] && had_binary=true
    info "正在下载并安装 Xray 核心..."
    if [[ -x "$xray_binary_path" ]]; then
        if ! cp -p "$xray_binary_path" "$xray_binary_backup_path"; then
            error "无法备份当前 Xray 核心，已终止安装。"
            return 1
        fi
    fi
    # --without-geodata: 官方 install 默认已含 geodata 下载，与下方
    # install-geodata 重复；统一由 install-geodata 负责。
    if ! execute_official_script "install" "--without-geodata"; then
        error "Xray 核心安装失败！请检查网络连接。"
        rollback_binary_and_service "$had_binary"
        return 1
    fi

    info "正在安装/更新 GeoIP 和 GeoSite 数据文件..."
    if ! execute_official_script "install-geodata"; then
        error "GeoIP/GeoSite 数据安装失败，正在恢复旧版本。"
        rollback_binary_and_service "$had_binary"
        return 1
    fi

    info "正在生成 Reality 密钥对..."
    local key_pair
    if ! key_pair=$($xray_binary_path x25519); then
        error "生成 Reality 密钥对失败！"
        rollback_binary_and_service "$had_binary"
        return 1
    fi
    local private_key public_key
    private_key=$(awk '/PrivateKey:/ {print $2}' <<< "$key_pair")
    public_key=$(awk '/^Password( \(PublicKey\))?:/ {print $NF}' <<< "$key_pair")
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常。"
        rollback_binary_and_service "$had_binary"
        return 1
    fi

    info "正在写入 Xray 配置文件..."
    if ! write_config "$port" "$uuid" "$domain" "$private_key" "$public_key"; then
        rollback_binary_and_service "$had_binary"
        return 1
    fi

    if ! restart_xray; then
        error "Xray 启动失败，正在恢复旧配置和核心。"
        if [[ "$had_config" == true ]]; then
            if restore_config_backup; then
                rollback_binary_and_service "$had_binary"
                error "已恢复旧配置和核心。"
            else
                error "旧配置恢复失败，请手动检查 ${xray_config_path}.bak。"
            fi
        else
            rm -f "$xray_config_path"
            rollback_binary_and_service "$had_binary"
        fi
        return 1
    fi

    rm -f "$xray_binary_backup_path"
    success "Xray 安装/配置成功！"
    view_subscription_info
}

press_any_key_to_continue() {
    printf '\n'
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

draw_divider() {
    printf "%0.s─" {1..48}
    printf "\n"
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        printf '%b\n' "${cyan} Xray VLESS-Reality 管理脚本${none}"
        printf '%b\n' "${yellow} Version: ${SCRIPT_VERSION}${none}"
        draw_divider
        check_xray_status
        printf '%b\n' "$xray_status_info"
        draw_divider
        # 修改：明确菜单项 1
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装/重装 Xray (VLESS-reality)"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Xray"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 Xray"
        draw_divider
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看 Xray 日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改节点配置"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看订阅信息"
        draw_divider
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出脚本"
        draw_divider
        if ! read -r -p "请输入选项 [0-7]: " choice; then
            info "检测到输入结束，退出脚本。"
            exit 0
        fi

        local needs_pause=true
        case $choice in
            1) ( install_xray ) || true ;;
            2) ( update_xray ) || true ;;
            3) ( restart_xray ) || true ;;
            4) ( uninstall_xray ) || true ;;
            5) ( view_xray_log ) || true; needs_pause=false ;;
            6) ( modify_config ) || true ;;
            7) ( view_subscription_info ) || true ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项，请输入 0-7 之间的数字。" ;;
        esac

        if [ "$needs_pause" = true ]; then
            press_any_key_to_continue
        fi
    done
}

# --- 脚本主入口 ---
main() {
    pre_check
    if [[ $# -gt 0 && "$1" == "install" ]]; then
        shift
        local port="" uuid="" domain=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --port|--uuid|--sni)
                    [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || {
                        error "参数 $1 缺少有效值。"
                        exit 2
                    }
                    case "$1" in
                        --port) port="$2" ;;
                        --uuid) uuid="$2" ;;
                        --sni) domain="$2" ;;
                    esac
                    shift 2 ;;
                *) error "未知参数: $1"; exit 1 ;;
            esac
        done
        [[ -z "$port" ]] && port=$default_port
        [[ -z "$uuid" ]] && uuid=$(generate_uuid)
        [[ -z "$domain" ]] && domain=$default_sni
        # 同端口重装豁免占用检查（xray 自身正监听原端口）
        local current_port=""
        [[ -f "$xray_config_path" ]] && current_port=$(jq -r '.inbounds[0].port // empty' "$xray_config_path" 2>/dev/null || true)
        local check_port=true
        [[ -n "$current_port" && "$port" == "$current_port" ]] && check_port=false
        if ! validate_config_args "$port" "$uuid" "$domain" "$check_port"; then
            error "参数无效。请检查端口、UUID或SNI域名格式。"
            exit 1
        fi
        run_install "$port" "$uuid" "$domain"
    else
        main_menu
    fi
}

# 兼容 bash <(curl ...)、直接执行与 curl ... | bash 管道方式；
# ${BASH_SOURCE[0]:-} 兼容 set -u 下管道模式的空数组
if [[ "${BASH_SOURCE[0]:-}" == "$0" || -z "${BASH_SOURCE[0]:-}" ]]; then
    main "$@"
fi
