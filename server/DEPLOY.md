# 服务器部署

网页入口：https://dianjie.org/account/
服务器：`alex@172.245.205.27`，源码目录 `/home/alex/pointverse/server`。

PointVerse 应用直接运行 Go 二进制，由 systemd 的 `pointverse` 服务管理，不再构建或运行应用 Docker 镜像。PostgreSQL 和 Caddy 仍使用现有容器，配置为 `compose.infrastructure.yaml`，沿用已有数据库和证书卷。

## 更新应用

上传修改后的服务端源码，保留服务器上的 `.env`、`app.env` 和数据目录，然后执行：

```sh
cd /home/alex/pointverse/server
bash deploy/update-native.sh
```

脚本先编译新程序，成功后执行迁移，替换二进制并重启应用，最后检查就绪状态。普通更新无需操作基础设施容器。

## 查看状态

```sh
systemctl status pointverse --no-pager
sudo journalctl -u pointverse -n 100 --no-pager
curl --fail http://127.0.0.1:8081/readyz
curl --fail https://dianjie.org/readyz
```

首次安装系统服务：

```sh
sudo install -m 0644 deploy/pointverse.service /etc/systemd/system/pointverse.service
sudo systemctl daemon-reload
sudo systemctl enable --now pointverse
```

`app.env` 保存数据库连接、监听地址和附件目录，权限为 600，不提交。应用监听 `127.0.0.1:8081`；Caddy 使用主机网络转发至该地址，应用仅信任 `127.0.0.1` 的转发头。附件保存于 `/home/alex/pointverse/data/cloud`。数据库只向主机回环地址发布 5432 端口。

## 基础设施

```sh
docker compose -f compose.infrastructure.yaml ps
docker compose -f compose.infrastructure.yaml up -d --wait
```

Caddy 使用 `Caddyfile.native` 自动签发和续期 dianjie.org 证书，并将 HTTP 跳转到 HTTPS。DNS 的 A 记录 `@` 指向 `172.245.205.27`。当前使用仅 DNS 模式；开启 Cloudflare 代理前应配置 Full (strict) 并适配受信代理的真实客户端 IP。

旧的 `compose.production.yaml` 和 `Caddyfile` 仅保留作容器部署参考，不再用于当前发布。旧应用容器已停止，旧附件卷保留作迁移前副本。数据库密码和已有数据库卷不得重建；不要使用 `down -v`。升级前应备份数据库与附件目录。
