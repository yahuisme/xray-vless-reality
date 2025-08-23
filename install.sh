#!/bin/bash

# Xray VLESS-Reality 多功能管理脚本
# 特点: 动态状态 | 美化菜单 | 修改配置 | 健壮性优化 | 规范化代码

# --- 颜色定义 ---
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

# --- 全局变量 ---
xray_config_path="/usr/local/etc/xray/config.json"
xray_binary_path="/usr/local/bin/xray"
xray_status_info=""

# --- 函数定义 ---
error() { echo -e "\n$red$1$none\n"; }
info() { echo -e "\n$yellow$1$none\n"; }
success() { echo -e "\n$green$1$none\n"; }

# 动画 Spinner
spinner() {
    local pid=$1
    local spinstr='|/-\'
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

# 检查前置环境
pre_check() {
    [[ $(id -u) != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [ ! -f /etc/debian_version ]; then
        error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。"
        exit 1
    fi

    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        (apt-get update && apt-get install -y jq curl) &> /dev/null
    fi
}

# 检查Xray的安装和运行状态
check_xray_status() {
    if [[ ! -f "$xray_binary_path" ]]; then
        xray_status_info="  Xray 状态: ${red}未安装${none}"
        return
    fi
    
    local xray_version=$($xray_binary_path version | head -n 1 | awk '{print $2}')
    local service_status
    if systemctl is-active --quiet xray; then
        service_status="${green}运行中${none}"
    else
        service_status="${yellow}未运行${none}"
    fi
    
    xray_status_info="  Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

# 1. 安装 / 更新 Xray
install_update_xray() {
    if [[ -f "$xray_binary_path" ]]; then
        info "检测到 Xray 已安装。继续操作将更新核心并覆盖现有配置。"
        read -p "是否继续？[y/N]: " confirm
        if [[ ! $confirm =~ ^[yY]$ ]]; then
            info "操作已取消。"
            return
        fi
    fi
    
    info "开始配置 Xray..."
    local port uuid domain shortid
    
    read -p "$(echo -e "请输入端口 [1-65535] (默认: ${cyan}443${none}): ")" port
    [ -z "$port" ] && port=443

    read -p "$(echo -e "请输入UUID (直接回车将使用随机UUID):\n${cyan}$(cat /proc/sys/kernel/random/uuid)${none}\n:")" uuid
    [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid)

    read -p "$(echo -e "请输入SNI域名 (默认: ${cyan}learn.microsoft.com${none}): ")" domain
    [ -z "$domain" ] && domain="learn.microsoft.com"
    
    shortid="20220701"

    info "正在下载并安装 Xray 核心..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install &> /dev/null &
    spinner $!
    if ! wait $!; then
        error "Xray 核心安装失败！请检查网络连接或官方脚本状态。"
        return
    fi
    
    info "正在生成 Reality 密钥对..."
    local key_pair=$($xray_binary_path x25519)
    local private_key=$(echo "$key_pair" | awk '/Private key:/ {print $3}')

    info "正在写入 Xray 配置文件..."
    cat > "$xray_config_path" <<-EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "0.0.0.0", "port": ${port}, "protocol": "vless", "settings": {"clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": false, "dest": "${domain}:443", "xver": 0, "serverNames": ["${domain}"], "privateKey": "${private_key}", "shortIds": ["${shortid}"]}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}}],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
    
    restart_xray
    success "Xray 安装/更新成功！"
    view_subscription_info
}

# 2. 修改配置
modify_config() {
    if [[ ! -f "$xray_config_path" ]]; then
        error "错误: Xray 未安装，无法修改配置。"
        return
    fi
    
    info "读取当前配置..."
    local current_port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local current_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local current_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    local private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$xray_config_path")
    local shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$xray_config_path")

    info "请输入新配置，直接回车则保留当前值。"
    read -p "$(echo -e "端口 (当前: ${cyan}${current_port}${none}): ")" port
    [ -z "$port" ] && port=$current_port

    read -p "$(echo -e "UUID (当前: ${cyan}${current_uuid}${none}): ")" uuid
    [ -z "$uuid" ] && uuid=$current_uuid

    read p "$(echo -e "SNI域名 (当前: ${cyan}${current_domain}${none}): ")" domain
    [ -z "$domain" ] && domain=$current_domain

    info "正在写入新配置..."
    cat > "$xray_config_path" <<-EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{"listen": "0.0.0.0", "port": ${port}, "protocol": "vless", "settings": {"clients": [{"id": "${uuid}", "flow": "xtls-rprx-vision"}], "decryption": "none"}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"show": false, "dest": "${domain}:443", "xver": 0, "serverNames": ["${domain}"], "privateKey": "${private_key}", "shortIds": ["${shortid}"]}}, "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}}],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

    restart_xray
    success "配置修改成功！"
    view_subscription_info
}

# 3. 卸载 Xray
uninstall_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then
        error "错误: Xray 未安装，无需卸载。"
        return
    fi
    read -p "您确定要卸载 Xray 吗？[y/N]: " confirm
    if [[ $confirm =~ ^[yY]$ ]]; then
        info "正在卸载 Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge &> /dev/null &
        spinner $!
        wait $!
        rm -f ~/xray_vless_reality_link.txt
        success "Xray 已成功卸载。"
    else
        info "卸载操作已取消。"
    fi
}

# 4. 重启 Xray
restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法重启。" && return; fi
    info "正在重启 Xray 服务..."
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        success "Xray 服务已成功重启！"
    else
        error "错误: Xray 服务启动失败, 请使用菜单 5 查看日志。"
    fi
}

# 5. 查看 Xray 实时日志
view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法查看日志。" && return; fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"
    journalctl -u xray -f --no-pager
}

# 6. 查看 VLESS Reality 订阅信息
view_subscription_info() {
    if [ ! -f "$xray_config_path" ]; then error "错误: 配置文件不存在, 请先安装。" && return; fi

    info "正在从配置文件生成订阅信息..."
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    local private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$xray_config_path")
    local shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$xray_config_path")
    local public_key=$(echo -n "${private_key}" | $xray_binary_path x25519 -i | awk '/Public key:/ {print $3}')
    local ip=$(curl -4s https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$' || curl -6s https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$')
    local display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"
    local link_name_encoded=$(echo "$(hostname) X-reality" | sed 's/ /%20/g')
    local vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=random&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"
    
    echo "${vless_url}" > ~/xray_vless_reality_link.txt
    echo "----------------------------------------------------------------"
    echo -e "$green --- Xray VLESS-Reality 订阅信息 --- $none"
    echo -e "$yellow 地址: $cyan$ip$none"
    echo -e "$yellow 端口: $cyan$port$none"
    echo -e "$yellow UUID: $cyan$uuid$none"
    echo -e "$yellow SNI: $cyan$domain$none"
    echo -e "$yellow 公钥: $cyan$public_key$none"
    echo -e "$yellow ShortId: $cyan$shortid$none"
    echo "----------------------------------------------------------------"
    echo -e "$green 订阅链接 (已保存到 ~/xray_vless_reality_link.txt): $none"
    echo -e "$cyan${vless_url}${none}"
    echo "----------------------------------------------------------------"
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "$cyan Xray VLESS-Reality 多功能管理脚本$none"
        echo "---------------------------------------------"
        check_xray_status
        echo -e "${xray_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装 / 更新 Xray"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "修改 Xray 配置"
        printf "  ${red}%-2s${none} %-35s\n" "3." "卸载 Xray"
        printf "  ${yellow}%-2s${none} %-35s\n" "4." "重启 Xray"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看 Xray 实时日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "查看 VLESS Reality 订阅信息"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "0." "退出脚本"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-6]: " choice

        case $choice in
            1) install_update_xray ;;
            2) modify_config ;;
            3) uninstall_xray ;;
            4) restart_xray ;;
            5) view_xray_log ;;
            6) view_subscription_info ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项，请输入 0-6 之间的数字。" ;;
        esac
        read -p "按 Enter 键返回主菜单..."
    done
}

# 脚本入口
pre_check
main_menu
