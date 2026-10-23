# PointVerse 服务端

Go 模块化单体的初始工程。当前包含 HTTP 服务、PostgreSQL 连接池、版本化数据库迁移和 Docker Compose 开发环境；邮箱网页注册与登录已接入，访问 [本地账户网页](http://localhost:8090/account/)，说明见 [网页注册](WEB.md)。Google / Apple 原生登录接口已接入，配置与协议见 [账户登录说明](AUTH.md)；手动上传与网页云端展示已实现，见 [同步说明](../docs/账户同步与网页展示.md)；AI 任务接口尚未实现。

## Docker 启动

以下 Docker 配置用于本地开发。线上 `https://dianjie.org` 直接运行 Go 程序，由 systemd 管理，更新步骤见 [服务器部署](DEPLOY.md)。

安装并启动 Docker Desktop 后，在本目录执行：

```sh
docker compose up --build -d
docker compose ps
curl --fail http://localhost:8080/healthz
curl --fail http://localhost:8080/readyz
```

如果 macOS 提示找不到 `docker` 或 `docker-credential-desktop`，可先为当前终端补齐 Docker Desktop 工具路径：

```sh
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
```

如果 Go 官方依赖源连接超时，可单独构建后启动：

```sh
docker compose build --build-arg GOPROXY=https://goproxy.cn
docker compose up -d --no-build
```

启动顺序：数据库健康 → 独立迁移进程成功退出 → API 启动。迁移进程退出码 0 是正常状态。

- `GET /healthz`：进程存活，返回 `{"status":"ok"}`。
- `GET /readyz`：数据库可连接且本程序包含的迁移全部完成，返回 `{"status":"ready"}`；否则返回 503，不暴露连接信息。
- `/account/`：邮箱注册、登录和账户页面；Docker 本机端口 8090。
- `/v1/auth/*`：邮箱、Google / Apple 登录及会话接口，未配置的第三方渠道默认关闭。
- `/web/auth/*`：浏览器 Cookie 会话接口。
- 其他路径返回 404。

查看日志及停止：

```sh
docker compose logs -f api
docker compose down
```

数据库保存在 `postgres_data` 命名卷，普通停止不会删除数据。Compose 内的账号密码仅用于本地开发。数据库和 8080 端口仅绑定回环地址；8090 端口已开放给局域网，真机通过 Mac 局域网地址访问。附件另存于 `cloud_data` 命名卷。

## 本地 Go 开发

需要 Go 1.25+。先启动数据库，再加载配置、执行迁移与启动：

```sh
docker compose up -d db
cp .env.example .env
set -a
. ./.env
set +a
go run ./cmd/migrate
go run ./cmd/server
```

程序从环境变量读取配置，不自动读取 `.env`；Compose 中数据库使用开发配置，Google/Apple Client ID 从项目 `.env` 或环境变量传入。

| 变量 | 说明 |
| --- | --- |
| `HTTP_ADDR` | HTTP 监听地址，默认 `:8080` |
| `DATABASE_URL` | 必填的 PostgreSQL 连接字符串 |
| `GOOGLE_CLIENT_IDS` | Google Client ID 白名单，逗号分隔，空值关闭渠道 |
| `APPLE_CLIENT_IDS` | Apple Client ID 白名单，原生为 Bundle ID，空值关闭渠道 |

## 验证

```sh
go test -race ./...
go vet ./...
go build ./...
```

数据库集成测试默认跳过。连接可创建临时 schema 的开发数据库后执行（测试会自动清理自己的 schema）：

```sh
TEST_DATABASE_URL="$DATABASE_URL" go test -race -timeout 120s ./...
```

## 目录和扩展边界

```text
cmd/server/                   HTTP 启动、信号处理和优雅退出
cmd/migrate/                  独立迁移命令
internal/config/              环境配置
internal/httpapi/             路由及健康检查
internal/auth/                第三方身份验证、账户、会话与限流
internal/database/            连接池、迁移和就绪检查
internal/database/migrations/ 内嵌的顺序 SQL 迁移
```

新增迁移采用递增文件名，如 `0002_accounts.sql`；已应用文件不应修改。迁移通过事务和 PostgreSQL advisory lock 避免并发重复执行，当前仅支持向前迁移。发布新镜像时应重新执行迁移命令；API 不自动修改表结构。

Dockerfile 采用多阶段构建、非 root 运行，支持 `linux/arm64` 和 `linux/amd64`：

```sh
docker buildx build --platform linux/arm64,linux/amd64 -t YOUR_REGISTRY/pointverse-server:dev --push .
```

后续按身份与设备、同步、附件、备份、后台任务逐步增加模块。原始内容、人工修改与可重建 AI 结果应分开建模；正式同步表结构需要先确定版本、冲突及加密协议。
