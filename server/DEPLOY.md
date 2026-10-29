# 服务器部署

网页入口：https://dianjie.org/account/
服务器：`alex@172.245.205.27`，源码目录 `/home/alex/pointverse/server`。

生产架构：VPS 的 Caddy 直接提供 H5 静态页面（`/account/`），接口通过 Tailscale 转发到 Mac mini `100.89.246.35:8081`。后端应用、PostgreSQL、用户附件与 AI 模型均运行或保存于 Mac mini。VPS 仅保存公开网页资源、入口配置与证书，不保存用户数据。`compose.infrastructure.yaml` 为 Caddy 挂载只读静态目录和证书卷。

Mac mini 目录：`~/Library/Application Support/PointVerse`；数据库 `data/postgres`，附件 `data/cloud`，迁移备份 `backups`。数据库仅监听 `127.0.0.1:15432`，应用只监听 Tailscale 地址。LaunchAgent 为 `org.dianjie.database`、`org.dianjie.server`、`org.dianjie.ai-gateway`，需保持 Mac 在线且用户会话可用。

VPS 上的 `PROXY_ONLY` 标记禁止旧部署脚本重新启用本地应用。更新生产应用时应构建 darwin/arm64 原生程序，部署到 Mac mini 的 `server`，再重启 `org.dianjie.server`；不要恢复 VPS 数据库或应用容器。以下旧单机部署命令仅保留作历史参考，不适用于当前生产架构。

## 更新 H5 静态页面

在本地仓库执行：

```sh
bash server/deploy/update-web.sh
```

只上传 `server/internal/webui/assets` 下的公开资源。VPS 静态目录为 `/home/alex/pointverse/web`，资源按校验和保存在 `releases`，`current` 链接原子切换。Caddy 只读挂载整个父目录，后续静态发布无需重启 Caddy 或 Mac 后端。若需回滚，将 `current` 切回之前的 release。不要在静态目录放密钥、数据库、附件或配置文件。

`/` 与 `/account` 在 VPS 重定向至 `/account/`；`/account/*` 由 VPS 文件服务处理，缺失资源直接返回 404。`/web/*`、`/v1/*` 和健康检查继续转发 Mac。HTML、JS、CSS 使用 `no-store`，带版本号的图标保留长期缓存。静态响应带 `X-PointVerse-Serving: vps-static`，可用于验证来源。

首次引入静态挂载前须先发布资源，再更新 `Caddyfile.native` 和 `compose.infrastructure.yaml`，校验 Caddy 配置后重建 Caddy；保留证书卷。Mac 中嵌入的页面仅作为开发备用，生产网页以 VPS 静态发布为准。

## 历史单机部署参考（不适用于当前架构）

以下命令仅记录迁移前的单机方式。当前后端应构建为 darwin/arm64 后部署到 Mac mini，不运行下面的 VPS 应用或数据库启动命令。

### 更新应用

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

## 独立手机端 H5

`h5.dianjie.org` 使用独立静态目录 `/home/alex/pointverse/h5`，与主站 `/home/alex/pointverse/web` 分开发布：

```sh
bash server/deploy/update-web.sh alex@172.245.205.27 h5
```

发布时将共享账户、生图、想法页面复制到手机端发布包，并加入专属首页和底部导航；无需维护重复的业务脚本。主站发布不影响手机端，反之亦然。当前首页提供录音记录、云端想法和生图功能；录音可通过 Mac 云端识别并保存，其他手机功能尚待接入。

该域名的 `/web/*`、`/v1/*`、健康检查转发至 Mac mini，其他路径由 VPS 提供静态文件，不将未知静态路径转发到 Mac。接口保留原始 Host 和 Origin 进行同源校验，使用仅限当前主机的 HttpOnly、Secure 会话 Cookie，不设置父域 Domain；主站与 H5 账户相同、浏览器登录会话独立。

Cloudflare 需要 `h5` 或有效的 `*` DNS 记录指向 `172.245.205.27`；橙云时使用 Full (strict)。Caddy 为该主机自动签发独立证书，DNS 未生效前无法完成公网 HTTPS 验证。

## Android 安装包与版本管理

公开下载页：`https://dianjie.org/downloads/android/`，账户网页也提供入口。APK、版本列表和下载页存放在 VPS 的 `/home/alex/pointverse/web/android`，沿用已有只读静态挂载，无需启停 Mac 后端。版本文件位于 `files/`，文件名含版本号、构建号、渠道与 SHA-256 前缀。

发布已构建的 Android 测试包：

```sh
bash server/deploy/publish-android.sh
# 或指定安装包、服务器和更新说明：
bash server/deploy/publish-android.sh /absolute/path/pointverse-debug.apk alex@172.245.205.27 '本次更新说明'
```

脚本检查 APK 签名、应用 ID 和 Android 9 最低版本，优先通过 rsync 复用上一安装包并只传差异（不可用时回退 scp），上传后在 VPS 再次校验文件大小与 SHA-256，然后原子更新 `releases.json` 的最新版指针。旧包不覆盖、不自动删除；同一包重复发布不产生重复历史。签名证书变更会拒绝发布，避免用户无法直接升级。后续构建必须保留同一调试签名文件，当前 SDK 构建签名已迁移到被 Git 忽略的 `android/.signing/debug.keystore`，清理 build 目录不会重新生成签名；仍应妥善备份，勿发布到公开目录。

首次发布仅在现有 Caddy 配置插入独立下载路由，保留其他线上配置；校验通过后热加载。配置或热加载失败会还原本次操作前的配置。账户首页入口通过复制当前线上静态版本后原子切换加入，保留线上其他资源。下载页与版本列表不缓存，带内容摘要的 APK 长期缓存，下载响应类型为 `application/vnd.android.package-archive`。

回退最新版（使用 `releases.json` 中现有文件名）：

```sh
ssh alex@172.245.205.27 python3 /home/alex/pointverse/tools/android-release.py \
  --root /home/alex/pointverse/web/android \
  --activate pointverse-VERSION-CODE-debug-SHA_PREFIX.apk
```

回退只更换网站推荐下载的版本，Android 系统可能拒绝安装较低 versionCode。发布与回退通过 SSH 管理，公开网页仅供查看与下载，不接受匿名上传。发布脚本的本地校验：`python3 server/deploy/test-android-release.py`。
