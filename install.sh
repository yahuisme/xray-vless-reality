#!/bin/bash

# =================================================================================================
# Script:         Xray-Reality All-in-One Management Script
# Version:        4.1 (Final Polished Release)
# Author:         (Your Name/ID, based on Crazypeace's original script)
# Description:    A comprehensive script to install, uninstall, update, and manage 
#                 Xray with VLESS-Reality protocol. Saves a snapshot of the config 
#                 for 100% reliable viewing.
# OS Support:     Debian 10+, Ubuntu 20.04+, CentOS 7+, RHEL, Fedora, AlmaLinux, Rocky Linux
# =================================================================================================

# --- Script Header and Colors ---
echo -e "                     _ ___                   \n ___ ___ __ __ ___ _| |  _|___ __ __   _ ___ \n|-_ |_  |  |  |-_ | _ |   |- _|  |  |_| |_  |\n|___|___|  _  |___|___|_|_|___|  _  |___|___|\n        |_____|               |_____|        "
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

# --- Global Variables ---
XRAY_CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN_FILE="/usr/local/bin/xray"
XRAY_INFO_FILE="/usr/local/etc/xray/last_config_display.txt"
PKG_MANAGER=""
OS_ID=""

# =================================================================================================
# --- Utility Functions ---
# =================================================================================================

error() {
    echo -e "\n$red[错误] $1$none\n"
    exit 1
}

warn() {
    echo -e "\n$yellow[警告] $1$none\n"
}

info() {
    echo -e "\n$green[信息] $1$none\n"
}

# =================================================================================================
# --- Core Logic Functions ---
# =================================================================================================

uninstall_script() {
    info "即将开始卸载 Xray..."
    systemctl stop xray
    systemctl disable xray >/dev/null 2>&1
    info "执行官方卸载脚本..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
    info "清理残留文件 (包括配置快照)..."
    rm -rf /usr/local/etc/xray
    rm -rf /var/log/xray
    info "Xray 已被彻底卸载。"
    exit 0
}

update_xray() {
    info "正在检查并更新 Xray 核心..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    info "正在检查并更新 geodata 文件..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata
    restart_xray
    info "Xray 更新完成。建议执行 '--show' 命令来查看最新配置（版本号等）。"
}

restart_xray() {
    info "正在重启 Xray 服务..."
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        info "Xray 服务已成功重启。"
    else
        error "Xray 服务重启失败, 请检查日志。"
    fi
}

view_logs() {
    info "按 Ctrl+C 退出日志查看。"
    journalctl -u xray -f --no-pager
}

display_result() {
    local p_port="$1"
    local p_uuid="$2"
    local p_sni="$3"
    local ip="$4"
    local public_key="$5"
    local shortid="$6"
    
    local node_name="$(hostname)-X-reality"
    local vless_url_ip=$ip
    if [[ "$ip" =~ .*:.* ]]; then vless_url_ip="[${ip}]"; fi
    local vless_reality_url="vless://${p_uuid}@${vless_url_ip}:${p_port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${p_sni}&fp=chrome&pbk=${public_key}&sid=${shortid}&#${node_name}"

    local output_text_colored
    # --- 修复：使用 ${var} 格式确保所有变量被正确解析 ---
    output_text_colored=$(cat <<-EOF
---------- 配置信息 ----------
${green} --- VLESS Reality 服务器配置 --- ${none}
${yellow} 节点名 (Name) = ${cyan}${node_name}${none}
${yellow} 地址 (Address) = ${cyan}${ip}${none}
${yellow} 端口 (Port) = ${cyan}${p_port}${none}
${yellow} 用户ID (UUID) = ${cyan}${p_uuid}${none}
${yellow} 流控 (Flow) = ${cyan}xtls-rprx-vision${none}
${yellow} SNI = ${cyan}${p_sni}${none}
${yellow} 指纹 (Fingerprint) = ${cyan}chrome${none}
${yellow} 公钥 (PublicKey) = ${cyan}${public_key}${none}
${yellow} ShortId = ${cyan}${shortid}${none}

---------- VLESS Reality URL ----------
${cyan}${vless_reality_url}${none}

----------------------------------------
EOF
)
    local output_text_plain
    output_text_plain=$(echo -e "$output_text_colored" | sed 's/\x1b\[[0-9;]*m//g')

    clear
    # 输出到屏幕 (带颜色)
    echo -e "$output_text_colored"

    # 将纯文本版本保存到快照文件
    echo "$output_text_plain" > "$XRAY_INFO_FILE"
    info "以上配置信息已保存至: $XRAY_INFO_FILE"
}

show_config() {
    info "正在读取上次保存的配置快照..."
    if [ ! -f "$XRAY_INFO_FILE" ]; then
        error "未找到配置快照文件。请先至少成功执行一次安装。"
    fi
    
    # 直接输出快照文件的内容，并通过 sed 添加颜色
    # 这样可以保证快照文件是纯文本，但显示时有颜色
    cat "$XRAY_INFO_FILE" | sed \
        -e "s/--- VLESS Reality 服务器配置 ---/${green}&${none}/" \
        -e "s/节点名 (Name) = /${yellow}&${cyan}/" \
        -e "s/地址 (Address) = /${yellow}&${cyan}/" \
        -e "s/端口 (Port) = /${yellow}&${cyan}/" \
        -e "s/用户ID (UUID) = /${yellow}&${cyan}/" \
        -e "s/流控 (Flow) = /${yellow}&${cyan}/" \
        -e "s/SNI = /${yellow}&${cyan}/" \
        -e "s/指纹 (Fingerprint) = /${yellow}&${cyan}/" \
        -e "s/公钥 (PublicKey) = /${yellow}&${cyan}/" \
        -e "s/ShortId = /${yellow}&${cyan}/" \
        -e "/^vless:\/\// s/.*/${cyan}&${none}/" | sed "s/$/${none}/"
    exit 0
}

install_xray() {
    local ip
    if [ "$IS_INTERACTIVE" = "true" ]; then
        warn "进入交互式安装模式..."
        if [[ -n "$IPv4" && -n "$IPv6" ]]; then
            read -p "检测到双栈网络, 请选择用于连接的网络栈 [默认: 4 (IPv4)]: (4/6) " p_netstack
            [ -z "$p_netstack" ] && p_netstack=4
        elif [[ -n "$IPv4" ]]; then p_netstack=4; else p_netstack=6; fi
        
        read -p "请输入监听端口 [1024-65535, 默认: 443]: " p_port; [ -z "$p_port" ] && p_port=443
        read -p "请输入SNI域名 [默认: learn.microsoft.com]: " p_sni; [ -z "$p_sni" ] && p_sni="learn.microsoft.com"
        read -p "请输入UUID [留空则自动生成]: " p_uuid
    else
        warn "检测到参数, 进入非交互式安装模式..."
    fi

    if [[ -z "$p_netstack" ]]; then
        if [[ -n "$IPv4" ]]; then p_netstack=4; else p_netstack=6; fi
    fi
    if [[ "$p_netstack" == "4" ]]; then ip=$IPv4; else ip=$IPv6; fi
    if [[ -z "$ip" ]]; then error "无法获取到任何公网IP地址。"; fi
    
    if [[ -z "$p_port" ]]; then p_port=443; fi
    if [[ -z "$p_sni" ]]; then p_sni="learn.microsoft.com"; fi

    if ! [[ "$p_port" =~ ^[0-9]+$ ]] || [ "$p_port" -lt 1 ] || [ "$p_port" -gt 65535 ]; then
        error "端口号无效, 请输入 1-65535 之间的数字。"
    fi
    if [ "$p_port" -le 1023 ]; then
        if [ "$(id -u)" -ne 0 ]; then
            error "错误: 非root用户无权使用 1-1023 范围内的周知端口。请选择 1024-65535 范围的端口。"
        else
            warn "您选择了一个周知端口 (${p_port})。通常建议使用 1024 以上的端口以避免潜在冲突。"
        fi
    fi

    if [[ -z "$p_uuid" ]]; then
        local uuidSeed=${IPv4}${IPv6}$(hostname)$(cat /etc/timezone)
        p_uuid=$(echo -n "https://github.com/crazypeace/xray-vless-reality${uuidSeed}" | sha1sum | awk '{print $1}' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/')
        warn "UUID已自动生成。"
    fi

    info "最终配置确认:"
    echo -e "$yellow  网络栈: ${cyan}IPv${p_netstack} (IP: ${ip})${none}"
    echo -e "$yellow  端口: ${cyan}${p_port}${none}"
    echo -e "$yellow  UUID: ${cyan}${p_uuid}${none}"
    echo -e "$yellow  SNI: ${cyan}${p_sni}${none}"
    echo "----------------------------------------------------------------"
    
    if [ "$IS_INTERACTIVE" = "true" ]; then
        read -p "确认以上配置并开始安装吗? (y/n): " confirm
        if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then info "安装已取消。"; exit 0; fi
    fi

    install_dependencies
    info "安装最新版本的 Xray-core..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    local keys=$($XRAY_BIN_FILE x25519)
    local private_key=$(echo "$keys" | awk '/Private key:/ {print $3}')
    local public_key=$(echo "$keys" | awk '/Public key:/ {print $3}')
    local shortid="20220701"

    info "配置 /usr/local/etc/xray/config.json..."
    cat > $XRAY_CONFIG_FILE <<-EOF
    {
      "log": { "loglevel": "warning" },
      "inbounds": [
        {
          "listen": "0.0.0.0",
          "port": ${p_port},
          "protocol": "vless",
          "settings": { "clients": [ { "id": "${p_uuid}", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
          "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
              "show": false,
              "dest": "${p_sni}:443",
              "xver": 0,
              "serverNames": ["${p_sni}"],
              "privateKey": "${private_key}",
              "shortIds": ["${shortid}"]
            }
          },
          "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
        }
      ],
      "outbounds": [
        { "protocol": "freedom", "tag": "direct" },
        { "protocol": "blackhole", "tag": "block" }
      ]
    }
EOF
    restart_xray
    display_result "$p_port" "$p_uuid" "$p_sni" "$ip" "$public_key" "$shortid"
}

# =================================================================================================
# --- Pre-flight Checks & System Detection ---
# =================================================================================================
if [[ $(id -u) -ne 0 ]]; then
    error "此脚本需要以root用户权限运行。请尝试使用 'sudo -i' 或 'sudo su' 切换用户后执行。"
fi

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        case $ID in
            debian|ubuntu)
                PKG_MANAGER="apt-get"
                ;;
            centos|rhel|fedora|almalinux|rocky)
                PKG_MANAGER="yum"
                if command -v dnf &>/dev/null; then
                    PKG_MANAGER="dnf"
                fi
                ;;
            *)
                error "不支持的操作系统: $ID"
                ;;
        esac
    else
        error "无法检测到操作系统, /etc/os-release 文件不存在。"
    fi
}

install_dependencies() {
    info "正在检查并安装核心依赖..."
    if [[ "$PKG_MANAGER" == "apt-get" ]]; then
        $PKG_MANAGER update -y &>/dev/null
        $PKG_MANAGER install -y curl sudo jq coreutils
    elif [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]]; then
        $PKG_MANAGER install -y curl sudo jq coreutils
    fi
}

display_help() {
    echo "Xray-Reality 一键管理脚本 V4.1"
    echo "----------------------------------------"
    echo "用法: $0 [动作] [选项]"
    echo
    echo "主要动作:"
    echo "  --install            执行安装流程 (可配合安装选项)。"
    echo "  --uninstall          执行卸载流程。"
    echo "  --update             更新Xray核心和GeoData。"
    echo "  --restart            重启Xray服务。"
    echo "  --logs               查看实时日志。"
    echo "  --show               显示上次安装的配置快照。"
    echo "  -h, --help           显示此帮助菜单。"
    echo
    echo "安装选项 (需配合 --install):"
    echo "  --netstack <4|6>     网络栈 (默认: 自动检测)。"
    echo "  --port <端口>        监听端口 (默认: 443)。"
    echo "  --uuid <UUID>        用户UUID (默认: 自动生成)。"
    echo "  --sni <域名>         SNI域名 (默认: learn.microsoft.com)。"
    echo
    echo "如果不带任何参数运行, 将显示交互式主菜单。"
    exit 0
}

# =================================================================================================
# --- Main Execution Block ---
# =================================================================================================
ACTION=""
p_netstack=""
p_port=""
p_uuid=""
p_sni=""
IS_INTERACTIVE="true"

if [[ $# -gt 0 ]]; then
    IS_INTERACTIVE="false"
    case "$1" in
        --install)
            ACTION="install"
            shift
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --netstack) p_netstack="$2"; shift 2;;
                --port) p_port="$2"; shift 2;;
                --uuid) p_uuid="$2"; shift 2;;
                --sni) p_sni="$2"; shift 2;;
                *) error "安装时使用了未知选项: $1";;
              esac
            done
            ;;
        --uninstall) ACTION="uninstall";;
        --update) ACTION="update";;
        --restart) ACTION="restart";;
        --logs) ACTION="logs";;
        --show) ACTION="show";;
        -h|--help) display_help;;
        *) error "未知动作: $1. 请使用 --help 查看可用命令。";;
    esac
fi

detect_os
IPv4=$(curl -4s -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$')
IPv6=$(curl -6s -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$')

main_menu() {
    clear
    echo "Xray-Reality 一键管理脚本 V4.1"
    echo "----------------------------------------"
    if [ -f "$XRAY_BIN_FILE" ]; then
        echo -e "当前状态: $green已安装$none"
        echo -e "版本: $($XRAY_BIN_FILE --version | head -n 1)"
    else
        echo -e "当前状态: $red未安装$none"
    fi
    echo "----------------------------------------"
    echo "请选择要执行的操作:"
    echo "[1] 安装 Xray"
    echo "[2] 卸载 Xray"
    echo "[3] 更新 Xray 核心"
    echo "[4] 重启 Xray 服务"
    echo "[5] 查看 Xray 日志"
    echo "[6] 显示当前配置"
    echo "[7] 退出脚本"
    echo "----------------------------------------"
    read -p "请输入选项 [1-7]: " choice

    case "$choice" in
        1) ACTION="install";;
        2) ACTION="uninstall";;
        3) ACTION="update";;
        4) ACTION="restart";;
        5) ACTION="logs";;
        6) ACTION="show";;
        7) exit 0;;
        *) error "无效输入,请输入 1-7 之间的数字。";;
    esac
}

if [ "$IS_INTERACTIVE" = "true" ]; then
    main_menu
fi

case "$ACTION" in
    install) install_xray;;
    uninstall) uninstall_script;;
    update) update_xray;;
    restart) restart_xray;;
    logs) view_logs;;
    show) show_config;;
esac
