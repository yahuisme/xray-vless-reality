#!/bin/bash

# ==============================================================================
# Script: Xray VLESS Reality One-Click Installer (Streamlined Version)
# Description: Installs Xray with VLESS Reality protocol.
# Features: Named arguments, focused installation, custom node name.
# Forked and Modified for specific, streamlined usage.
# ==============================================================================

# --- Script Header and Colors ---
# 等待1秒, 避免curl下载脚本的打印与脚本本身的显示冲突
sleep 1

echo -e "                     _ ___                   \n ___ ___ __ __ ___ _| |  _|___ __ __   _ ___ \n|-_ |_  |  |  |-_ | _ |   |- _|  |  |_| |_  |\n|___|___|  _  |___|___|_|_|___|  _  |___|___|\n        |_____|               |_____|        "
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

# --- Utility Functions ---
error() {
    echo -e "\n$red$1$none\n"
    exit 1
}

warn() {
    echo -e "\n$yellow$1$none\n"
}

pause() {
    read -rsp "$(echo -e "按 $green Enter 回车键 $none 继续....或按 $red Ctrl + C $none 取消.")" -d $'\n'
    echo
}

display_help() {
    echo "Xray VLESS Reality 一键安装脚本 (精简版)"
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  --netstack <4|6>     指定使用的网络栈 (IPv4 或 IPv6)。默认自动检测。"
    echo "  --port <端口号>      指定监听端口 (1-65535)。默认 443。"
    echo "  --uuid <UUID>        指定用户 UUID。默认基于主机信息生成。"
    echo "  --sni <域名>         指定服务器名称指示 (SNI)。默认 learn.microsoft.com。"
    echo "  -h, --help           显示此帮助菜单并退出。"
    echo
    exit 0
}


# --- Default Settings ---
p_netstack=""
p_port=""
p_uuid=""
p_sni=""


# --- Parse Command-Line Arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --netstack)
      p_netstack="$2"
      shift 2
      ;;
    --port)
      p_port="$2"
      shift 2
      ;;
    --uuid)
      p_uuid="$2"
      shift 2
      ;;
    --sni)
      p_sni="$2"
      shift 2
      ;;
    -h|--help)
      display_help
      ;;
    *)
      error "未知选项: $1"
      ;;
  esac
done


# --- Main Logic ---

# 脚本说明
echo
echo -e "$yellow此脚本仅兼容于Debian 10+系统。如果你的系统不符合,请Ctrl+C退出脚本$none"
echo -e "这是一个精简版本, 移除了WARP和二维码功能, 使用 -h 或 --help 查看帮助。"
echo "----------------------------------------------------------------"

# 获取本机IP
InFaces=($(ls /sys/class/net/ | grep -E '^(eth|ens|eno|esp|enp|venet|vif)'))
IPv4=""
IPv6=""
for i in "${InFaces[@]}"; do
    Public_IPv4=$(curl -4s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    Public_IPv6=$(curl -6s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    if [[ -n "$Public_IPv4" ]]; then IPv4="$Public_IPv4"; fi
    if [[ -n "$Public_IPv6" ]]; then IPv6="$Public_IPv6"; fi
done

# --- 变量最终确定 ---

# 确定网络栈和IP
ip=""
if [[ -z "$p_netstack" ]]; then
    if [[ -n "$IPv4" ]]; then
        p_netstack=4
        ip=$IPv4
    elif [[ -n "$IPv6" ]]; then
        p_netstack=6
        ip=$IPv6
    else
        error "无法获取到任何公网IP地址。"
    fi
else
    if [[ "$p_netstack" == "4" ]]; then ip=$IPv4; fi
    if [[ "$p_netstack" == "6" ]]; then ip=$IPv6; fi
    if [[ -z "$ip" ]]; then error "指定的网络栈 (IPv${p_netstack}) 没有获取到公网IP地址。"; fi
fi

# 确定端口
if [[ -z "$p_port" ]]; then p_port=443; fi
# 验证端口
if ! [[ "$p_port" =~ ^[0-9]+$ ]] || [ "$p_port" -lt 1 ] || [ "$p_port" -gt 65535 ]; then
    error "端口号无效, 请输入 1-65535 之间的数字。"
fi

# 确定SNI
if [[ -z "$p_sni" ]]; then p_sni="learn.microsoft.com"; fi

# 确定UUID
if [[ -z "$p_uuid" ]]; then
    uuidSeed=${IPv4}${IPv6}$(cat /proc/sys/kernel/hostname)$(cat /etc/timezone)
    p_uuid=$(echo -n "https://github.com/crazypeace/xray-vless-reality${uuidSeed}" | sha1sum | awk '{print $1}' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/')
fi

# --- 配置总览 ---
echo "安装配置总览:"
echo -e "$yellow  网络栈 (Netstack) = ${cyan}${p_netstack} (IP: ${ip})${none}"
echo -e "$yellow  端口 (Port) = ${cyan}${p_port}${none}"
echo -e "$yellow  用户ID (UUID) = ${cyan}${p_uuid}${none}"
echo -e "$yellow  服务器名 (SNI) = ${cyan}${p_sni}${none}"
echo "----------------------------------------------------------------"
pause

# --- 系统准备 ---
apt update
apt install -y curl sudo jq net-tools lsof

# --- 安装 Xray ---
echo
warn "安装最新版本的 Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
warn "更新 geodata..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata

# --- 生成密钥和ShortID ---
keys=$(xray x25519)
private_key=$(echo "$keys" | awk '/Private key:/ {print $3}')
public_key=$(echo "$keys" | awk '/Public key:/ {print $3}')
shortid=$(openssl rand -hex 8)

echo
echo "密钥信息:"
echo -e "$yellow  私钥 (PrivateKey) = ${cyan}${private_key}${none}"
echo -e "$yellow  公钥 (PublicKey) = ${cyan}${public_key}${none}"
echo -e "$yellow  ShortId = ${cyan}${shortid}${none}"
echo "----------------------------------------------------------------"

# --- 开启BBR ---
echo
warn "开启 BBR..."
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
echo "net.core.default_qdisc = fq" >>/etc/sysctl.conf
sysctl -p >/dev/null 2>&1

# --- 配置 Xray config.json ---
echo
warn "配置 /usr/local/etc/xray/config.json..."
cat > /usr/local/etc/xray/config.json <<-EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${p_port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${p_uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
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
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF

# --- 重启并输出配置 ---
warn "重启 Xray 服务..."
service xray restart
sleep 1
service xray status

# 获取节点名
node_name="$(hostname)-reality"

echo
echo "---------- Xray 配置信息 -------------"
echo -e "$green ---VLESS Reality 服务器配置--- $none"
echo -e "$yellow 节点名 (Name) = $cyan${node_name}$none"
echo -e "$yellow 地址 (Address) = $cyan${ip}$none"
echo -e "$yellow 端口 (Port) = ${cyan}${p_port}${none}"
echo -e "$yellow 用户ID (UUID) = $cyan${p_uuid}${none}"
echo -e "$yellow 流控 (Flow) = ${cyan}xtls-rprx-vision${none}"
echo -e "$yellow 加密 (Encryption) = ${cyan}none${none}"
echo -e "$yellow 传输协议 (Network) = ${cyan}tcp${none}"
echo -e "$yellow 底层传输安全 (TLS) = ${cyan}reality$none"
echo -e "$yellow SNI = ${cyan}${p_sni}$none"
echo -e "$yellow 指纹 (Fingerprint) = ${cyan}chrome${none}"
echo -e "$yellow 公钥 (PublicKey) = ${cyan}${public_key}${none}"
echo -e "$yellow ShortId = ${cyan}${shortid}${none}"
echo
echo "---------- VLESS Reality URL ----------"
vless_url_ip=$ip
if [[ "$p_netstack" == "6" ]]; then vless_url_ip="[${ip}]"; fi
vless_reality_url="vless://${p_uuid}@${vless_url_ip}:${p_port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${p_sni}&fp=chrome&pbk=${public_key}&sid=${shortid}&#${node_name}"
echo -e "${cyan}${vless_reality_url}${none}"
echo
echo "---------- END -------------"
echo
warn "安装流程结束。"
