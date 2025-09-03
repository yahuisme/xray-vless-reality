#!/bin/bash

# ==============================================================================
# Xray VLESS-Reality 一键安装管理脚本
# 版本: V-Final
# 更新日志 (V-Final):
# - [修正] 修复了修改配置后，因缺少暂停导致配置信息一闪而过的问题。
# - [修正] 修复了 `write_config` 函数因使用 heredoc 方式构建 JSON 可能导致意外中断的BUG。
# ==============================================================================

# --- Shell 严格模式 (重要优化) ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="V-Final"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"


# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
xray_status_info=""

# --- 辅助函数 ---
error() { echo -e "\n$red[✖] $1$none\n" >&2; }
info() { echo -e "\n$yellow[!] $1$none\n"; }
success() { echo -e "\n$green[✔] $1$none\n"; }

spinner() {
    local pid=$1; local spinstr='|/-\'
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    error "无法获取公网 IP 地址。" && return 1
}

execute_official_script() {
    local args="$1"
    local script_content
    script_content=$(curl -L "$xray_install_script_url")
    if [[ -z "$script_content" ]]; then
        error "下载 Xray 官方安装脚本失败！请检查网络连接。"
        return 1
    fi
    bash -c "$script_content" @ $args &> /dev/null &
    spinner $!
    if ! wait $!; then
        return 1
    fi
}

# --- 预检查与环境设置 ---
pre_check() {
    [[ $(id -u) != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [ ! -f /etc/debian_version ]; then error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。" && exit 1; fi

    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        (DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl) &> /dev/null &
        spinner $!
        if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
            error "依赖 (jq/curl) 自动安装失败。请手动运行 'apt update && apt install -y jq curl' 后重试。"
            exit 1
        fi
        success "依赖已成功安装。"
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" ]]; then xray_status_info="  Xray 状态: ${red}未安装${none}"; return; fi
    local xray_version=$($xray_binary_path version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未知")
    local service_status
    if systemctl is-active --quiet xray 2>/dev/null; then service_status="${green}运行中${none}"; else service_status="${yellow}未运行${none}"; fi
    xray_status_info="  Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

is_valid_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_valid_domain() {
    local domain=$1
    [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]
}

# --- 菜单功能函数 ---
install_xray() {
    if [[ -f "$xray_binary_path" ]]; then
        info "检测到 Xray 已安装。继续操作将覆盖现有配置。"
        read -p "是否继续？[y/N]: " confirm
        if [[ ! $confirm =~ ^[yY]$ ]]; then info "操作已取消。"; return; fi
    fi
    info "开始配置 Xray..."
    local port uuid domain

    while true; do
        read -p "$(echo -e "请输入端口 [1-65535] (默认: ${cyan}443${none}): ")" port
        [ -z "$port" ] && port=443
        if is_valid_port "$port"; then break; else error "端口无效，请输入一个1-65535之间的数字。"; fi
    done

    read -p "$(echo -e "请输入UUID (留空将默认生成随机UUID): ")" uuid
    if [[ -z "$uuid" ]]; then uuid=$(cat /proc/sys/kernel/random/uuid); info "已为您生成随机UUID: ${cyan}${uuid}${none}"; fi

    while true; do
        read -p "$(echo -e "请输入SNI域名 (默认: ${cyan}learn.microsoft.com${none}): ")" domain
        [ -z "$domain" ] && domain="learn.microsoft.com"
        if is_valid_domain "$domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done

    run_install "$port" "$uuid" "$domain"
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法执行更新。请先选择安装选项。" && return; fi
    info "正在检查最新版本..."
    local current_version=$($xray_binary_path version | head -n 1 | awk '{print $2}')
    local latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/v//' || echo "")
    if [[ -z "$latest_version" ]]; then error "获取最新版本号失败，请检查网络或稍后再试。" && return; fi
    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"
    if [[ "$current_version" == "$latest_version" ]]; then success "您的 Xray 已是最新版本，无需更新。" && return; fi
    info "发现新版本，开始更新..."

    if ! execute_official_script "install"; then error "Xray 核心更新失败！" && return; fi

    info "正在更新 GeoIP 和 GeoSite 数据文件..."
    execute_official_script "install-geodata"

    restart_xray && success "Xray 更新成功！"
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法重启。" && return; fi
    info "正在重启 Xray 服务..."
    if systemctl restart xray; then
        sleep 1
        success "Xray 服务已成功重启！"
    else
        error "错误: Xray 服务启动失败, 请使用菜单 5 查看日志。"
        return 1
    fi
}

uninstall_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无需卸载。" && return; fi
    read -p "您确定要卸载 Xray 吗？这将删除所有相关文件。[Y/n]: " confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then
        info "卸载操作已取消。"
        return
    fi
    info "正在卸载 Xray..."
    if execute_official_script "remove --purge"; then
        rm -f ~/xray_vless_reality_link.txt
        success "Xray 已成功卸载。"
    else
        error "Xray 卸载失败！"
        return 1
    fi
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法查看日志。" && return; fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

modify_config() {
    if [[ ! -f "$xray_config_path" ]]; then error "错误: Xray 未安装，无法修改配置。" && return; fi
    info "读取当前配置..."
    local current_port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local current_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local current_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    local private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$xray_config_path")
    local public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path")

    info "请输入新配置，直接回车则保留当前值。"
    local port uuid domain
    while true; do
        read -p "$(echo -e "端口 (当前: ${cyan}${current_port}${none}): ")" port
        [ -z "$port" ] && port=$current_port
        if is_valid_port "$port"; then break; else error "端口无效，请输入一个1-65535之间的数字。"; fi
    done
    read -p "$(echo -e "UUID (当前: ${cyan}${current_uuid}${none}): ")" uuid; [ -z "$uuid" ] && uuid=$current_uuid
    while true; do
        read -p "$(echo -e "SNI域名 (当前: ${cyan}${current_domain}${none}): ")" domain
        [ -z "$domain" ] && domain=$current_domain
        if is_valid_domain "$domain"; then break; else error "域名格式无效，请重新输入。"; fi
    done

    write_config "$port" "$uuid" "$domain" "$private_key" "$public_key"
    restart_xray
    success "配置修改成功！"
    view_subscription_info
}

view_subscription_info() {
    if [ ! -f "$xray_config_path" ]; then error "错误: 配置文件不存在, 请先安装。" && return; fi
    info "正在从配置文件生成订阅信息..."
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    local public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path")
    local shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$xray_config_path")
    if [[ -z "$public_key" ]]; then error "配置文件中缺少公钥信息,可能是旧版配置,请重新安装以修复。" && return; fi

    local ip
    ip=$(get_public_ip)

    local display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"
    local link_name="$(hostname) X-reality"
    local link_name_encoded=$(echo "$link_name" | sed 's/ /%20/g')
    local vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"

    echo "${vless_url}" > ~/xray_vless_reality_link.txt
    echo "----------------------------------------------------------------"
    echo -e "$green --- Xray VLESS-Reality 订阅信息 --- $none"
    echo -e "$yellow 名称: $cyan$link_name$none"
    echo -e "$yellow 地址: $cyan$ip$none"
    echo -e "$yellow 端口: $cyan$port$none"
    echo -e "$yellow UUID: $cyan$uuid$none"
    echo -e "$yellow 流控: $cyan"xtls-rprx-vision"$none"
    echo -e "$yellow 指纹: $cyan"chrome"$none"
    echo -e "$yellow SNI: $cyan$domain$none"
    echo -e "$yellow 公钥: $cyan$public_key$none"
    echo -e "$yellow ShortId: $cyan$shortid$none"
    echo "----------------------------------------------------------------"
    echo -e "$green 订阅链接 (已保存到 ~/xray_vless_reality_link.txt): $none\n"; echo -e "$cyan${vless_url}${none}"
    echo "----------------------------------------------------------------"
}

# --- 核心逻辑函数 ---
write_config() {
    local port=$1 uuid=$2 domain=$3 private_key=$4 public_key=$5 shortid="20220701"
    jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg domain "$domain" \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg shortid "$shortid" \
    '{
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "listen": "0.0.0.0",
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": ($domain + ":443"),
                    "xver": 0,
                    "serverNames": [$domain],
                    "privateKey": $private_key,
                    "publicKey": $public_key,
                    "shortIds": [$shortid]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"]
            }
        }],
        "outbounds": [{
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv4v6"
            }
        }]
    }' > "$xray_config_path"
}

run_install() {
    local port=$1 uuid=$2 domain=$3
    info "正在下载并安装 Xray 核心..."
    if ! execute_official_script "install"; then
        error "Xray 核心安装失败！请检查网络连接。"
        exit 1
    fi

    info "正在生成 Reality 密钥对..."
    local key_pair=$($xray_binary_path x25519)
    local private_key=$(echo "$key_pair" | grep 'PrivateKey:' | cut -d ' ' -f2)
    local public_key=$(echo "$key_pair" | grep 'Password:' | cut -d ' ' -f2)
    if [[ -z "$private_key" || -z "$public_key" ]]; then
        error "生成 Reality 密钥对失败！请检查 Xray 核心是否正常。"
        exit 1
    fi

    info "正在写入 Xray 配置文件..."
    write_config "$port" "$uuid" "$domain" "$private_key" "$public_key"

    restart_xray

    success "Xray 安装/配置成功！"
    view_subscription_info
}

press_any_key_to_continue() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

main_menu() {
    while true; do
        clear
        echo -e "$cyan Xray VLESS-Reality 一键安装管理脚本$none"
        echo "---------------------------------------------"
        check_xray_status
        echo -e "${xray_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装/重装 Xray"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Xray"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 Xray"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看 Xray 日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改节点配置"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看订阅信息"
        echo "---------------------------------------------"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出脚本"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-7]: " choice

        local needs_pause=true
        case $choice in
            1) install_xray ;;
            2) update_xray ;;
            3) restart_xray ;;
            4) uninstall_xray ;;
            5) view_xray_log; needs_pause=false ;;
            # [修正] 去掉了 needs_pause=false，确保在显示完配置后能够暂停
            6) modify_config ;;
            7) view_subscription_info ;;
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
                --port) port="$2"; shift 2 ;;
                --uuid) uuid="$2"; shift 2 ;;
                --sni) domain="$2"; shift 2 ;;
                *) error "未知参数: $1"; exit 1 ;;
            esac
        done
        [[ -z "$port" ]] && port=443
        [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
        [[ -z "$domain" ]] && domain="learn.microsoft.com"
        if ! is_valid_port "$port" || ! is_valid_domain "$domain"; then
            error "参数无效。请检查端口或SNI域名格式。" && exit 1
        fi
        info "开始非交互式安装..."
        run_install "$port" "$uuid" "$domain"
    else
        main_menu
    fi
}

main "$@"
