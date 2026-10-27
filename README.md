# xray-vless-reality

一键安装和管理 Xray 的 **VLESS + REALITY + Vision**，无需自有域名或证书。客户端须支持此组合。

## 使用

需要 **Debian/Ubuntu 及兼容系统、root、Bash、curl、systemd**；在交互终端运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh)
```

选择 `1` 安装，默认端口 `443`、SNI `www.sega.com`，UUID 自动生成。SNI 目标须从服务器可达并支持 TLS 1.3（443）。

安装后将节点链接导入客户端，并在服务器防火墙及云安全组放行所选 **TCP 端口**。

## 管理

再次运行上方命令，按菜单更新、重启、卸载、修改配置或查看节点链接与日志。

- 配置：`/usr/local/etc/xray/config.json`；备份：同路径加 `.bak`。
- 节点链接：`/root/xray_vless_reality_link.txt`，含连接凭据，请勿公开。
- 日志：`journalctl -u xray -f --no-pager`，按 Ctrl+C 退出。
- **安装 / 重装覆盖整个 Xray 配置，含自定义内容，请先备份；重装后重新导入节点。**
- 修改仅调整首个 VLESS-Reality 入站的端口、首个用户 UUID 和 SNI，回车保留当前值；其他配置保留。更换 SNI 会同步目标为该域名的 443 端口，修改后更新客户端节点。
- 更新保留配置、服务文件及原运行状态，失败时尝试回滚。
- **卸载清除整个 Xray、配置、备份、日志及节点信息，含自定义内容；确认时回车即同意。**

<details>
<summary>无交互安装与参数</summary>

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yahuisme/xray-vless-reality/main/install.sh) install --port 443 --sni www.sega.com
```

`--port` 默认 `443`，`--uuid` 不填自动生成，`--sni` 默认 `www.sega.com`。无交互安装同样覆盖已有配置，不询问重装确认。

在首次命令末尾加 `--help` 或 `install --help` 查看帮助。

</details>

回滚失败时保留 `/var/lib/xray-vless-reality/pending`；其中 `paths` 按行列出原路径，对应从 `0` 开始的编号快照。先人工恢复并核对配置和服务状态，再移走目录；恢复前脚本会阻止安装、更新、修改和卸载。
