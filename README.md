# xray-vless-reality

一键安装和管理 Xray 的 VLESS + REALITY + Vision（`xtls-rprx-vision`）。客户端须支持此组合；VLESS `encryption=none` 表示不启用 VLESS Encryption，由 REALITY 提供传输安全。

SNI 是 REALITY 目标域名，须从服务器可达并支持 TLS 1.3；脚本连接其 443 端口，无需自有域名或证书。

当前版本：`v26.09.11`

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

- `--port <端口>`：1–65535，默认 443
- `--uuid <UUID>`
- `--sni <域名>`：默认 `www.sega.com`

未填写 UUID 时会自动生成。`--help` 和 `install --help` 无需 root；未知或多余参数返回退出码 2。

## 文件

- 配置：`/usr/local/etc/xray/config.json`
- 配置备份：`/usr/local/etc/xray/config.json.bak`
- 节点链接：`/root/xray_vless_reality_link.txt`
- 实时日志：`journalctl -u xray -f --no-pager`，按 Ctrl+C 退出。

## 菜单功能

安装、更新、重启、卸载、查看日志、修改配置和查看节点链接。

卸载会清除整个 Xray 及其配置、备份、日志和节点信息，含自定义内容；确认提示回车即同意。

重装会覆盖配置；修改仅调整首个 VLESS-Reality 入站的端口、首个用户 UUID 和 SNI，保留其他配置；更换 SNI 会同步目标为该域名:443。更新保留服务文件与原运行状态，失败恢复核心和 geodata；恢复失败会显示保留的恢复目录。请自行放行节点端口。
