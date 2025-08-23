#!/bin/bash

# Xray VLESS-Reality 一键安装管理脚本

# --- 全局常量 ---
SCRIPT_VERSION="v5.2"
SCRIPT_URL="https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh"
xray_config_path="/usr/local/etc/xray/config.json"
xray_binary_path="/usr/local/bin/xray"

# --- 颜色定义 ---
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

# --- 全局变量 ---
xray_status_info=""

# --- 函数定义 ---
error() { echo -e "\n$red$1$none\n"; }
info() { echo -e "\n$yellow$1$none\n"; }
success() { echo -e "\n$green$1$none\n"; }

spinner() {
    local pid=$1; local spinstr='|/-\-';
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}; printf " [%c]  " "$spinstr";
        local spinstr=$temp${spinstr%"$temp"}; sleep 0.1; printf "\r";
    done; printf "    \r";
}

pre_check() {
    [[ $(id -u) != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [ ! -f /etc/debian_version ]; then error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。" && exit 1; fi
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        (apt-get update && apt-get install -y jq curl) &> /dev/null
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" ]]; then xray_status_info="  Xray 状态: ${red}未安装${none}"; return; fi
    local xray_version=$($xray_binary_path version | head -n 1 | awk '{print $2}')
    local service_status
    if systemctl is-active --quiet xray; then service_status="${green}运行中${none}"; else service_status="${yellow}未运行${none}"; fi
    xray_status_info="  Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

# --- 菜单功能函数 ---
install_xray() {
    if [[ -f "$xray_binary_path" ]]; then
        info "检测到 Xray 已安装。继续操作将覆盖现有配置。"; read -p "是否继续？[y/N]: " confirm
        if [[ ! $confirm =~ ^[yY]$ ]]; then info "操作已取消。"; return; fi
    fi
    info "开始配置 Xray..."
    local port uuid domain
    read -p "$(echo -e "请输入端口 [1-65535] (默认: ${cyan}443${none}): ")" port; [ -z "$port" ] && port=443
    read -p "$(echo -e "请输入UUID (留空将默认生成随机UUID): ")" uuid
    if [[ -z "$uuid" ]]; then uuid=$(cat /proc/sys/kernel/random/uuid); info "已为您生成随机UUID: ${cyan}${uuid}${none}"; fi
    read -p "$(echo -e "请输入SNI域名 (默认: ${cyan}learn.microsoft.com${none}): ")" domain; [ -z "$domain" ] && domain="learn.microsoft.com"
    run_install "$port" "$uuid" "$domain"
    success "Xray 安装成功！"
    view_subscription_info
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法执行更新。请先选择安装选项。" && return; fi
    info "正在更新 Xray 核心程序..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install &> /dev/null &
    spinner $!; if ! wait $!; then error "Xray 核心更新失败！请检查网络连接。" && return; fi
    info "正在更新 GeoIP 和 GeoSite 数据文件..."; bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata &> /dev/null &
    spinner $!; wait $!
    restart_xray; success "Xray 更新成功！"
}

uninstall_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无需卸载。" && return; fi
    read -p "您确定要卸载 Xray 吗？这将删除所有相关文件。[Y/n]: " confirm
    if [[ $confirm =~ ^[nN]$ ]]; then
        info "卸载操作已取消。"
    else
        info "正在卸载 Xray..."; bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge &> /dev/null &
        spinner $!; wait $!; rm -f ~/xray_vless_reality_link.txt; success "Xray 已成功卸载。"
    fi
}

modify_config() {
    if [[ ! -f "$xray_config_path" ]]; then error "错误: Xray 未安装，无法修改配置。" && return; fi
    info "读取当前配置..."; local current_port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local current_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local current_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    # 读取私钥和公钥
    local private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$xray_config_path")
    local public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path")

    info "请输入新配置，直接回车则保留当前值。"; read -p "$(echo -e "端口 (当前: ${cyan}${current_port}${none}): ")" port; [ -z "$port" ] && port=$current_port
    read -p "$(echo -e "UUID (当前: ${cyan}${current_uuid}${none}): ")" uuid; [ -z "$uuid" ] && uuid=$current_uuid
    read -p "$(echo -e "SNI域名 (当前: ${cyan}${current_domain}${none}): ")" domain; [ -z "$domain" ] && domain=$current_domain

    # 写入配置时传入公钥和私钥
    write_config "$port" "$uuid" "$domain" "$private_key" "$public_key"; 
    restart_xray; 
    success "配置修改成功！"; 
    view_subscription_info
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法重启。" && return; fi
    info "正在重启 Xray 服务..."; systemctl restart xray; sleep 1
    if systemctl is-active --quiet xray; then success "Xray 服务已成功重启！"; else error "错误: Xray 服务启动失败, 请使用菜单 6 查看日志。"; fi
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法查看日志。" && return; fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"; journalctl -u xray -f --no-pager
}

view_subscription_info() {
    if [ ! -f "$xray_config_path" ]; then error "错误: 配置文件不存在, 请先安装。" && return; fi
    info "正在从配置文件生成订阅信息..."; 
    
    # 直接从配置文件读取所有需要的信息
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    local public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path")
    local shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$xray_config_path")
    
    if [[ -z "$public_key" ]]; then
        error "配置文件中缺少公钥信息,可能是旧版配置,请重新安装以修复。"
        return
    fi

    local ip=$(curl -4s https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$' || curl -6s https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$')
    local display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"
    local link_name_encoded=$(echo "$(hostname) X-reality" | sed 's/ /%20/g')
    local vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"
    
    echo "${vless_url}" > ~/xray_vless_reality_link.txt
    echo "----------------------------------------------------------------"
    echo -e "$green --- Xray VLESS-Reality 订阅信息 --- $none"
    echo -e "$yellow 地址: $cyan$ip$none"; echo -e "$yellow 端口: $cyan$port$none"; echo -e "$yellow UUID: $cyan$uuid$none"
    echo -e "$yellow 流控: $cyan"xtls-rprx-vision"$none"; echo -e "$yellow 指纹: $cyan"chrome"$none"; echo -e "$yellow SNI: $cyan$domain$none"
    echo -e "$yellow 公钥: $cyan$public_key$none"; echo -e "$yellow ShortId: $cyan$shortid$none"
    echo "----------------------------------------------------------------"
    echo -e "$green 订阅链接 (已保存到 ~/xray_vless_reality_link.txt): $none\n"; echo -e "$cyan${vless_url}${none}"
    echo "----------------------------------------------------------------"
}

update_script() {
    info "正在检查脚本更新...";
    local tmp_file="/tmp/install.sh.tmp"
    if ! curl -sL "$SCRIPT_URL" -o "$tmp_file"; then error "下载新版脚本失败！请检查网络连接。" && return; fi
    if [[ ! -s "$tmp_file" ]]; then error "下载的文件为空，更新失败。" && rm -f "$tmp_file" && return; fi
    chmod +x "$tmp_file"; mv "$tmp_file" "$0"; success "脚本已更新！将自动重启以加载新版本..."; sleep 2; exec "$0"
}

# --- 核心逻辑函数 ---
write_config() {
    local port=$1 uuid=$2 domain=$3 private_key=$4 public_key=$5 shortid="20220701"
    # 将公钥也写入配置文件中，作为信息源
    local config_content=$(jq -n \
        --argjson port "$port" \
        --arg uuid "$uuid" \
        --arg domain "$domain" \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg shortid "$shortid" \
        '{
          "log": {"loglevel": "warning"},
          "inbounds": [{
            "listen": "0.0.0.0", "port": $port, "protocol": "vless",
            "settings": {"clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}], "decryption": "none"},
            "streamSettings": {
              "network": "tcp", "security": "reality",
              "realitySettings": {
                "show": false, "dest": ($domain + ":443"), "xver": 0,
                "serverNames": [$domain], "privateKey": $private_key, "publicKey": $public_key,
                "shortIds": [$shortid]
              }
            },
            "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
          }],
          "outbounds": [{"protocol": "freedom"}]
        }')
    echo "$config_content" > "$xray_config_path"
}

run_install() {
    local port=$1 uuid=$2 domain=$3
    info "正在下载并安装 Xray 核心..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install &> /dev/null &
    spinner $!; if ! wait $!; then error "Xray 核心安装失败！请检查网络连接。"; exit 1; fi
    info "正在生成 Reality 密钥对..."; 
    local key_pair=$($xray_binary_path x25519)
    local private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')
    local public_key=$(echo "$key_pair" | awk '/Public key:/ {print $3}')
    
    info "正在写入 Xray 配置文件..."; 
    write_config "$port" "$uuid" "$domain" "$private_key" "$public_key"
    
    info "正在启动 Xray 服务..."; systemctl restart xray; sleep 1
    if ! systemctl is-active --quiet xray; then error "Xray 服务启动失败！"; exit 1; fi
}

non_interactive_install() {
    local port=$1 uuid=$2 domain=$3
    run_install "$port" "$uuid" "$domain"
    success "Xray 无交互安装成功！"
    view_subscription_info
}

main_menu() {
    while true; do
        clear
        echo -e "$cyan Xray VLESS-Reality 一键安装管理脚本$none"
        echo "---------------------------------------------"
        check_xray_status
        echo -e "${xray_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装 Xray"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "3." "卸载 Xray"
        printf "  ${cyan}%-2s${none} %-35s\n" "4." "重启 Xray"
        printf "  ${yellow}%-2s${none} %-35s\n" "5." "修改 Xray 配置"
        printf "  ${magenta}%-2s${none} %-35s\n" "6." "查看 Xray 日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "7." "查看订阅信息"
        printf "  ${green}%-2s${none} %-35s\n" "8." "升级脚本"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "0." "退出脚本"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-8]: " choice
        case $choice in
            1) install_xray ;; 2) update_xray ;; 3) uninstall_xray ;; 4) restart_xray ;;
            5) modify_config ;; 6) view_xray_log ;; 7) view_subscription_info ;; 8) update_script ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项，请输入 0-8 之间的数字。" ;;
        esac; read -p "按 Enter 键返回主菜单..."
    done
}

# --- 脚本入口 ---
pre_check
if [ "$#" -ge 3 ]; then
    non_interactive_install "$1" "$2" "$3"
else
    main_menu
fi
