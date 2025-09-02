#!/bin/bash

# Xray VLESS-Reality-PQE 一键安装管理脚本
#
# * 支持最新的后量子加密 (Post-Quantum Encryption, PQE)
# * 交互模式下默认开启PQE (Y/n)
# * 非交互模式下默认关闭，需加 --pqe 参数开启
# * 优化节点名称格式 (X-PQE / X-reality)
#

# --- 全局常量 ---
SCRIPT_VERSION="V-PQE-Final-v11"
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

# 进程等待动画
spinner() {
    local pid=$1; local spinstr='|/-\-'
    while ps -p $pid > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

# 预检
pre_check() {
    [[ $(id -u) != 0 ]] && error "错误: 您必须以root用户身份运行此脚本" && exit 1
    if [ ! -f /etc/debian_version ]; then error "错误: 此脚本仅支持 Debian/Ubuntu 及其衍生系统。" && exit 1; fi

    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "检测到缺失的依赖 (jq/curl)，正在尝试自动安装..."
        (apt-get update && apt-get install -y jq curl) &> /dev/null &
        spinner $!
        if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
            error "依赖 (jq/curl) 自动安装失败。请手动运行 'apt update && apt install -y jq curl' 后重试。"
            exit 1
        fi
        success "依赖已成功安装。"
    fi
}

# 检查 Xray 状态
check_xray_status() {
    if [[ ! -f "$xray_binary_path" ]]; then xray_status_info="  Xray 状态: ${red}未安装${none}"; return; fi
    local xray_version=$($xray_binary_path version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未知")
    local service_status
    if systemctl is-active --quiet xray 2>/dev/null; then service_status="${green}运行中${none}"; else service_status="${yellow}未运行${none}"; fi
    xray_status_info="  Xray 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${xray_version}${none}"
}

# 验证端口
is_valid_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then return 0; else return 1; fi
}

# 验证域名
is_valid_domain() {
    local domain=$1
    if [[ "$domain" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$domain" != *--* ]]; then return 0; else return 1; fi
}

# --- 菜单功能函数 ---
install_xray() {
    if [[ -f "$xray_binary_path" ]]; then
        info "检测到 Xray 已安装。继续操作将覆盖现有配置。"
        read -p "是否继续？[y/N]: " confirm
        if [[ ! $confirm =~ ^[yY]$ ]]; then info "操作已取消。"; return; fi
    fi
    info "开始配置 Xray..."
    local port uuid domain enable_pqe

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

    # 交互模式下，默认开启PQE
    read -p "$(echo -e "是否启用后量子加密(PQE)？(Y/n): ")" enable_pqe

    run_install "$port" "$uuid" "$domain" "$enable_pqe" "interactive"
}

update_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法执行更新。请先选择安装选项。" && return; fi
    info "正在检查最新版本..."
    local current_version=$($xray_binary_path version | head -n 1 | awk '{print $2}')
    local latest_version=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name' | sed 's/v//')
    if [[ -z "$latest_version" ]]; then error "获取最新版本号失败，请检查网络或稍后再试。" && return; fi
    info "当前版本: ${cyan}${current_version}${none}，最新版本: ${cyan}${latest_version}${none}"
    if [[ "$current_version" == "$latest_version" ]]; then success "您的 Xray 已是最新版本，无需更新。" && return; fi
    info "发现新版本，开始更新..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install &> /dev/null &
    spinner $!; if ! wait $!; then error "Xray 核心更新失败！请检查网络连接。" && return; fi
    info "正在更新 GeoIP 和 GeoSite 数据文件..."; bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata &> /dev/null &
    spinner $!; wait $!
    restart_xray && success "Xray 更新成功！"
}

restart_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法重启。" && return; fi
    info "正在重启 Xray 服务..."; systemctl restart xray; sleep 1
    if systemctl is-active --quiet xray; then success "Xray 服务已成功重启！"; else error "错误: Xray 服务启动失败, 请使用菜单 5 查看日志。"; fi
}

uninstall_xray() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无需卸载。" && return; fi
    read -p "您确定要卸载 Xray 吗？这将删除所有相关文件。[Y/n]: " confirm
    if [[ $confirm =~ ^[nN]$ ]]; then
        info "卸载操作已取消。"
    else
        info "正在卸载 Xray..."; bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge &> /dev/null &
        spinner $!; wait $!; rm -f ~/xray_pqe_link.txt; success "Xray 已成功卸载。"
    fi
}

view_xray_log() {
    if [[ ! -f "$xray_binary_path" ]]; then error "错误: Xray 未安装，无法查看日志。" && return; fi
    info "正在显示 Xray 实时日志... 按 Ctrl+C 退出。"; journalctl -u xray -f --no-pager
}

modify_config() {
    if [[ ! -f "$xray_config_path" ]]; then error "错误: Xray 未安装，无法修改配置。" && return; fi
    info "读取当前配置...";
    local current_port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local current_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local current_domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    local current_pqe=$(jq -r '.inbounds[0].streamSettings.realitySettings.cipherSuites // "null"' "$xray_config_path")
    local private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$xray_config_path")
    local public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path")

    local pqe_status_text="${red}关闭${none}"
    if [[ "$current_pqe" != "null" ]]; then pqe_status_text="${green}开启${none}"; fi

    info "请输入新配置，直接回车则保留当前值。"
    local port uuid domain enable_pqe
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

    # 交互模式下，修改配置时默认开启
    read -p "$(echo -e "是否启用后量子加密(PQE) (当前: ${pqe_status_text}) [Y/n]: ")" enable_pqe
    if [[ -z "$enable_pqe" ]]; then
        enable_pqe="y"
    fi

    write_config "$port" "$uuid" "$domain" "$private_key" "$public_key" "$enable_pqe";
    restart_xray && success "配置修改成功！" && view_subscription_info
}

view_subscription_info() {
    if [ ! -f "$xray_config_path" ]; then error "错误: 配置文件不存在, 请先安装。" && return; fi
    info "正在从配置文件生成订阅信息...";
    local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$xray_config_path")
    local port=$(jq -r '.inbounds[0].port' "$xray_config_path")
    local domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    local public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "$xray_config_path")
    local shortid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$xray_config_path")
    local pqe_status=$(jq -r '.inbounds[0].streamSettings.realitySettings.cipherSuites // "null"' "$xray_config_path")

    if [[ -z "$public_key" ]]; then error "配置文件中缺少公钥信息,可能是旧版配置,请重新安装以修复。" && return; fi

    local ip=$(curl -4s https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$' || curl -6s https://www.cloudflare.com/cdn-cgi/trace | grep -oP 'ip=\K.*$')
    local display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"

    local link_name="$(hostname) X-reality"
    local pqe_status_text="${red}关闭${none}"
    if [[ "$pqe_status" != "null" ]]; then
        pqe_status_text="${green}开启${none}"
        link_name="$(hostname) P-reality"
    fi

    local link_name_encoded=$(echo "$link_name" | sed 's/ /%20/g')
    local vless_url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${public_key}&sid=${shortid}#${link_name_encoded}"

    echo "${vless_url}" > ~/xray_pqe_link.txt
    echo "----------------------------------------------------------------"
    echo -e "$green --- Xray VLESS-Reality 订阅信息 --- $none"
    echo -e "$yellow 名称: $cyan$link_name$none"
    echo -e "$yellow 地址: $cyan$ip$none"
    echo -e "$yellow 端口: $cyan$port$none"
    echo -e "$yellow UUID: $cyan$uuid$none"
    echo -e "${yellow} 流控: ${cyan}xtls-rprx-vision${none}"
    echo -e "${yellow} 传输安全: ${cyan}reality${none}"
    echo -e "$yellow 后量子加密: $pqe_status_text"
    echo -e "$yellow 指纹: $cyan"chrome"$none"
    echo -e "$yellow SNI: $cyan$domain$none"
    echo -e "$yellow 公钥: $cyan$public_key$none"
    echo -e "$yellow ShortId: $cyan$shortid$none"
    echo "----------------------------------------------------------------"
    echo -e "$green 订阅链接 (已保存到 ~/xray_pqe_link.txt): $none\n"; echo -e "$cyan${vless_url}${none}"
    echo "----------------------------------------------------------------"
    if [[ "$pqe_status" != "null" ]]; then
        info "注意：PQE 需要较新版本的客户端才能完全生效。旧客户端仍可正常连接，但会自动降级为常规加密。"
    fi
}


# --- 核心逻辑函数 ---
write_config() {
    local port=$1 uuid=$2 domain=$3 private_key=$4 public_key=$5 enable_pqe=$6
    local shortid="20220701"

    local reality_settings_jq_str
    if [[ "$enable_pqe" =~ ^[yY]$ ]]; then
        info "启用后量子加密 (PQE)..."
        reality_settings_jq_str=$(jq -n \
            --arg domain "$domain" --arg private_key "$private_key" --arg public_key "$public_key" --arg shortid "$shortid" \
            '{
                "show": false, "dest": ($domain + ":443"), "xver": 0, "serverNames": [$domain],
                "privateKey": $private_key, "publicKey": $public_key, "shortIds": [$shortid],
                "cipherSuites": "TLS_AES_128_GCM_SHA256:X25519_KYBER768"
            }'
        )
    else
        info "未启用后量子加密..."
        reality_settings_jq_str=$(jq -n \
            --arg domain "$domain" --arg private_key "$private_key" --arg public_key "$public_key" --arg shortid "$shortid" \
            '{
                "show": false, "dest": ($domain + ":443"), "xver": 0, "serverNames": [$domain],
                "privateKey": $private_key, "publicKey": $public_key, "shortIds": [$shortid]
            }'
        )
    fi

    local config_content=$(jq -n \
        --argjson port "$port" --arg uuid "$uuid" --argjson realitySettings "$reality_settings_jq_str" \
        '{
            "log": {"loglevel": "warning"},
            "inbounds": [{
                "listen": "0.0.0.0", "port": $port, "protocol": "vless",
                "settings": {
                    "clients": [{"id": $uuid, "flow": "xtls-rprx-vision"}],
                    "decryption": "none"
                },
                "streamSettings": {
                    "network": "tcp", "security": "reality",
                    "realitySettings": $realitySettings
                },
                "sniffing": {
                    "enabled": true, "destOverride": ["http", "tls", "quic"]
                }
            }],
            "outbounds": [{"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4v6"}}]
        }')

    echo "$config_content" > "$xray_config_path"
}

run_install() {
    local port=$1 uuid=$2 domain=$3 enable_pqe=$4 mode=$5
    info "正在下载并安装 Xray 核心..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install &> /dev/null &
    spinner $!; if ! wait $!; then error "Xray 核心安装失败！请检查网络连接。"; exit 1; fi

    info "正在生成 Reality 密钥对...";
    local key_pair=$($xray_binary_path x25519)
    local private_key=$(echo "$key_pair" | awk '/PrivateKey:/ {print $2}')
    local public_key=$(echo "$key_pair" | awk '/Password:/ {print $2}')

    info "正在写入 Xray 配置文件...";
    # 仅在交互式安装模式下，当用户直接回车时，默认为 'y'
    if [[ "$mode" == "interactive" && -z "$enable_pqe" ]]; then
        enable_pqe="y"
    fi
    write_config "$port" "$uuid" "$domain" "$private_key" "$public_key" "$enable_pqe"

    systemctl enable xray &>/dev/null
    info "正在启动 Xray 服务..."; systemctl restart xray; sleep 1
    if ! systemctl is-active --quiet xray; then error "Xray 服务启动失败！"; exit 1; fi

    success "Xray 安装/配置成功！"
    view_subscription_info
}

main_menu() {
    while true; do
        clear
        echo -e "$cyan Xray VLESS-Reality-PQE 一键安装管理脚本$none"
        echo "---------------------------------------------"
        check_xray_status
        echo -e "${xray_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装 Xray"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Xray"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 Xray"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看 Xray 日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改节点配置"
        printf "  ${cyan}%-2s${none} %-35s\n" "7." "查看订阅信息"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "0." "退出脚本"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-7]: " choice

        case $choice in
            1) install_xray; read -p "按 Enter 键返回主菜单..." ;;
            2) update_xray; read -p "按 Enter 键返回主菜单..." ;;
            3) restart_xray; read -p "按 Enter 键返回主菜单..." ;;
            4) uninstall_xray; read -p "按 Enter 键返回主菜单..." ;;
            5) view_xray_log ;;
            6) modify_config; read -p "按 Enter 键返回主菜单..." ;;
            7) view_subscription_info; read -p "按 Enter 键返回主菜单..." ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项，请输入 0-7 之间的数字。" && sleep 2 ;;
        esac
    done
}

# --- 非交互式安装相关函数 ---
non_interactive_usage() {
    echo "非交互式安装用法: "
    echo "  $0 install --port <端口> --uuid <UUID> --sni <域名> [--pqe]"
    echo "参数说明:"
    echo "  --port   必需，指定监听端口。"
    echo "  --uuid   必需，指定用户UUID。"
    echo "  --sni    必需，指定伪装的SNI域名。"
    echo "  --pqe    可选，添加此参数以开启PQE。如果省略，则默认不开启。"
}

non_interactive_dispatcher() {
    if [[ "$1" != "install" ]]; then
        error "非交互式模式仅支持 'install' 命令。"
        exit 1
    fi
    shift

    local port="" uuid="" domain="" enable_pqe="n" # 非交互模式下，默认不开启PQE
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port) port="$2"; shift 2 ;;
            --uuid) uuid="$2"; shift 2 ;;
            --sni) domain="$2"; shift 2 ;;
            --pqe) enable_pqe="y"; shift 1 ;; # 加上参数即开启
            *) error "未知参数: $1"; non_interactive_usage; exit 1 ;;
        esac
    done

    # 验证必需参数
    if [[ -z "$port" || -z "$uuid" || -z "$domain" ]]; then
        error "错误: --port, --uuid, --sni 是必需参数。"
        non_interactive_usage
        exit 1
    fi

    # 验证参数格式
    if ! is_valid_port "$port" || ! is_valid_domain "$domain"; then
        error "参数格式无效。请检查端口或SNI域名。"
        exit 1
    fi
    
    info "开始非交互式安装..."
    # 非交互模式调用 run_install，不传递 mode 参数
    run_install "$port" "$uuid" "$domain" "$enable_pqe"
}

# --- 脚本入口 ---
# 将所有函数定义放在前面，最后再执行调用
main() {
    pre_check
    if [[ $# -gt 0 ]]; then
        non_interactive_dispatcher "$@"
    else
        main_menu
    fi
}

# 确保所有函数都已加载，最后执行main函数
main "$@"
