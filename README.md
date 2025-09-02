# xray-vless-reality

基于 Xray 核心的 VLESS-reality 极简一键安装脚本
支持最新的后量子加密 (Post-Quantum Encryption, PQE)

## 功能特点

1. 交互管理菜单
2. 可自定义端口、UUID 和 sni 网址
3. 支持带参数一键无交互安装
4. 支持最新的后量子加密 (Post-Quantum Encryption, PQE)
5. 支持菜单修改配置参数
6. 支持菜单管理脚本
7. 极简纯净高效

## 一键脚本

```
bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh)
```

## 无交互安装脚本

```
bash <(curl -L https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh) install --port 12345 --uuid 'd0f6a483-51b3-44eb-94b6-1f5fc9272c81' --sni 'www.sega.com --pqe'
```

可实现一键无交互安装，直接输出订阅链接。自行替换端口、UUID 和 sni 网址。
