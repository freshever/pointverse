# 网页邮箱注册与登录

本地浏览器入口：<http://localhost:8090/account/>。根路径自动跳转到注册页。网页资源嵌入 Go 程序，无需单独安装前端依赖；Docker 同一个 API 容器映射两个本机端口：8080 用于原有接口，8090 用于网页访问，两者提供同一服务。

## 已实现流程

1. 邮箱、密码和确认密码注册；密码需要 12–128 个字符，可使用 Unicode，不截断或去除密码空格。
2. 服务端规范化邮箱大小写与外层空格，阻止重复注册；密码使用独立随机盐的 Argon2id 保存。
3. 注册成功自动登录并显示账户信息；刷新页面保持会话。
4. 已有账户可使用邮箱和密码登录；退出后服务端会话立即撤销。
5. 浏览器会话使用 HttpOnly、SameSite=Strict Cookie，不把 token 返回给 JavaScript，也不存入 localStorage。

目前**不发送验证邮件**，邮箱身份明确保存并显示为未验证；不因填写一个邮箱就声称用户拥有它。邮箱验证、重置密码与发送邮件需要后续接入邮件服务。邮箱账户不按相同邮箱自动合并到 Google / Apple 账户。

## 端口与运行

```sh
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker compose build --build-arg GOPROXY=https://goproxy.cn
docker compose up -d --no-build --wait
```

目前映射 `8090:8080`，Mac 本机和同一局域网的 iPhone 均可访问。PostgreSQL 继续使用持久化卷。

## 接口

| 方法与路径 | 说明 |
| --- | --- |
| `POST /v1/auth/email/register` | 原生客户端注册，返回与第三方登录相同的 Bearer 会话 |
| `POST /v1/auth/email/login` | 原生客户端邮箱登录，返回 Bearer 会话 |
| `POST /web/auth/register` | 浏览器注册，设置 Cookie，只返回 user 和 expires_at |
| `POST /web/auth/login` | 浏览器登录，设置 Cookie，只返回 user 和 expires_at |
| `GET /web/auth/me` | 读取 Cookie 并返回当前 user |
| `POST /web/auth/logout` | 撤销 Cookie 对应会话，并清除 Cookie |

注册请求：

```json
{"email":"you@example.com","password":"your long passphrase","password_confirmation":"your long passphrase"}
```

登录请求只需 email、password。状态码：注册成功 201、登录成功 200、退出 204；重复邮箱 409 / email_exists，错误密码 401 / invalid_credentials，参数问题 400。

浏览器写入接口要求与请求目标完全匹配的 Origin（包括协议与端口），GET 查询不需要 Origin。登录/注册请求使用 application/json；拒绝未知字段和超大请求。Cookie 只用于 `/web/`，原有 `/v1/auth/me` 与 `/v1/auth/logout` 仍使用 Bearer 令牌。

密码运算最多同时处理两次，且共享已有的每 IP 每分钟 20 次限流。静态页面设置 CSP，不加载第三方脚本。

当前端口是本地 HTTP 开发入口。正式部署应使用 HTTPS；当前 Cookie 在直接 TLS 请求下设置 Secure。若在 TLS 终止反向代理后部署，需要先明确配置受信代理、Secure Cookie 和外部 Origin，当前代码不会盲目信任转发头。

服务器直接运行 Go 应用，由 systemd 管理；Caddy 为 `https://dianjie.org` 终止 TLS，并通过回环地址转发到应用。`TRUSTED_PROXY_IP=127.0.0.1` 显式信任本机代理；其他来源的转发头不会被采用。详见 [部署说明](DEPLOY.md)。

## 验证

```sh
TEST_DATABASE_URL='postgres://pointverse:pointverse_dev@localhost:5432/pointverse?sslmode=disable' go test -race -timeout 120s ./...
go vet ./...
node --check internal/webui/assets/app.js
```

集成测试在独立临时 schema 中运行，覆盖密码比较和随机盐、并发重复注册、同邮箱跨渠道隔离、Cookie 生命周期、跨站拦截、登录和退出。浏览器实测覆盖注册、刷新、退出及重新登录，测试账户在验证后清理。

## 云端展示

登录后进入 `/account/library.html`，查看 iOS 选中上传的文字、图片、录音。同步协议、范围和存储边界见 [账户同步与网页展示](../docs/账户同步与网页展示.md)。
