# xray-vless-reality

一键安装和管理 Xray 的 VLESS-Reality。

当前版本：`v26.08.29`

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh)
```

需要 Debian/Ubuntu 及兼容系统、systemd 和 root 权限。

## 无交互安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh) install \
  --port 443 --sni www.sega.com
```

可选参数：

- `--port <端口>`
- `--uuid <UUID>`
- `--sni <域名>`

未填写 UUID 时会自动生成。

## 文件

- 配置：`/usr/local/etc/xray/config.json`
- 配置备份：`/usr/local/etc/xray/config.json.bak`
- 节点链接：`/root/xray_vless_reality_link.txt`

## 菜单功能

安装、更新、重启、卸载、查看日志、修改配置和查看节点链接。
