# xray-vless-reality
Xray Vless-Reality 极简一键脚本

# 说明 
fork自 https://github.com/crazypeace/xray-vless-reality

# 一键安装
```
apt update
apt install -y curl
```
```
bash <(curl -sL https://raw.githubusercontent.com/yahuisme/xray-vless-reality/refs/heads/main/install.sh)
```

# 客户端参数配置
脚本最后会输出VLESS链接，方便你导入翻墙客户端。

如果你是手搓VLESS链接，那么参考：https://github.com/XTLS/Xray-core/discussions/716
如 `vless://${xray_id}@${ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&type=tcp#VLESS_R_${ip}`

# Uninstall
```
bash <(curl -sL https://raw.githubusercontent.com/yahuisme/xray-vless-reality/refs/heads/main/install.sh) --uninstall
```

# 脚本支持带参数运行
```
bash <(curl -sL https://raw.githubusercontent.com/yahuisme/xray-vless-reality/refs/heads/main/install.sh) --port [port] --uuid [UUID] --sni [domain]
```

其中

`port` 端口. 不写的话, 默认443

`domain` 你指定的网站域名. 不写的话, 默认 learn.microsoft.com

`UUID` 你的UUID. 不写的话, 自动生成
