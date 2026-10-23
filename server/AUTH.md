# Google / Apple 账户登录

服务端已实现原生 App 的 ID Token 登录：客户端通过官方 SDK 完成授权，服务端验证凭证并创建自己的账户与会话。目前不提供浏览器 OAuth 回调，不要求用户设置密码，也不访问 Google / Apple 密码。独立的邮箱密码注册已增加，见 [网页注册流程](WEB.md)。

当前未申请第三方应用标识，两种渠道默认关闭。设置允许的 Client ID 后才开启相应渠道；不会接受测试身份或跳过签名验证。iOS 登录界面与 SDK 已接入，配置步骤见 [iOS 账户登录](../ios/AccountLogin.md)。真实授权仍需申请标识后联调。

## 申请及配置

### Google

1. 在 Google Cloud 创建项目，配置 Google Auth Platform 的应用信息、目标用户与测试用户。
2. 为 iOS 创建 OAuth Client ID，Bundle ID 使用当前项目的 `org.dianjie.pv`。
3. 为后端身份验证创建 Web 类型 OAuth Client ID；客户端以后配置 `GIDClientID`、`GIDServerClientID` 和回调 URL scheme。
4. 服务端 `GOOGLE_CLIENT_IDS` 填入本项目允许的 Client ID，英文逗号分隔。使用后端 Client ID 时，也要包含作为 `azp` 返回的 iOS Client ID。只允许自己控制的应用标识。

原生接入和后端校验见 [Google iOS 接入说明](https://developers.google.com/identity/sign-in/ios/start-integrating) 与 [Google 后端认证说明](https://developers.google.com/identity/sign-in/ios/backend-auth)。服务端校验固定签发方与官方公钥、RS256 签名、aud/azp 白名单、exp、iat 和 sub。

### Apple

1. 在 Apple Developer 的 Identifiers 中，为 `org.dianjie.pv` 启用 Sign in with Apple。
2. 后续为 iOS target 添加相同能力，更新签名配置。
3. 服务端设置 `APPLE_CLIENT_IDS=org.dianjie.pv`。仅在确实启用该 App ID 后配置；未来 Web 登录需要单独的 Services ID 与回调流程。

参见 [Apple 能力配置](https://developer.apple.com/help/account/capabilities/about-sign-in-with-apple/) 和 [Apple 身份验证说明](https://developer.apple.com/documentation/signinwithapple/verifying-a-user)。本期仅校验原生身份令牌，不调用授权码换取刷新令牌的接口，所以不需要在服务端配置 Apple 私钥或 Client Secret。

### 启动配置

在 `server/` 执行一次 `cp .env.example .env`，然后编辑 `.env` 的公开应用标识。不要覆盖已有的 `.env`。Compose 会读取并传入这两个配置项：

```dotenv
GOOGLE_CLIENT_IDS=YOUR_WEB_CLIENT_ID,YOUR_IOS_CLIENT_ID
APPLE_CLIENT_IDS=org.dianjie.pv
```

未准备好的渠道留空。然后：

```sh
docker compose build --build-arg GOPROXY=https://goproxy.cn
docker compose up -d --no-build --wait
curl --fail http://localhost:8080/v1/auth/providers
```

渠道开关只表示配置了 Client ID，不代表已经完成真实账号授权联调。正式环境通过 HTTPS 传输凭证。

## API 协议

所有响应携带 `Cache-Control: no-store`。登录请求只接受 `application/json`，未知字段、额外 JSON、超大请求会被拒绝；登录与挑战接口按来源 IP 共享每分钟 20 次限制。

| 方法与路径 | 功能 |
| --- | --- |
| `GET /v1/auth/providers` | 返回 `{"google":false,"apple":false}` 等当前配置 |
| `POST /v1/auth/google` | 验证 Google ID Token，首次登录自动创建账户 |
| `POST /v1/auth/apple/challenge` | 生成 10 分钟有效、一次性 Apple 登录挑战 |
| `POST /v1/auth/apple` | 验证 Apple ID Token 与挑战，首次登录自动创建账户 |
| `GET /v1/auth/me` | 使用 `Authorization: Bearer <access_token>` 查询当前账户 |
| `POST /v1/auth/logout` | 撤销当前会话，返回 204；重复退出仍返回 204 |

### Google 登录

客户端用 Google SDK 获得本应用的 `idToken.tokenString`，提交：

```json
{"id_token":"GOOGLE_ID_TOKEN"}
```

同一 ID Token 只允许成功换取一次会话。客户端应保存成功返回的 PointVerse 会话；明确退出后重新授权取得新的 Google ID Token。若成功响应丢失，再次提交会返回 `invalid_identity_token`，需要重新授权。当前不实现幂等重领会话或第三方 Token 刷新。

### Apple 登录

先调用 `POST /v1/auth/apple/challenge`：

```json
{"challenge_id":"RANDOM_ID","nonce":"RANDOM_NONCE","expires_at":"2026-10-22T14:00:00Z"}
```

在原生 `ASAuthorizationAppleIDRequest` 中，将 `request.nonce` **原样设为返回的 nonce**。不要自行再做 SHA-256，否则与本协议不匹配。取得 `identityToken` 后提交：

```json
{"id_token":"APPLE_ID_TOKEN","challenge_id":"RANDOM_ID"}
```

服务端验证签名后的 nonce 与挑战匹配，再在创建会话的同一事务中消费挑战。失败不会消耗正确挑战，成功后不能重放。Apple 的隐藏邮箱按实际签名结果保存；不要求 Apple 返回姓名，不信任请求体提供的邮箱或用户 ID。

### 登录成功与后续请求

两种渠道均返回 200，示意：

```json
{
  "access_token":"POINTVERSE_RANDOM_SESSION_TOKEN",
  "token_type":"Bearer",
  "expires_at":"2026-10-29T14:00:00Z",
  "user":{
    "id":"UUID",
    "display_name":"",
    "created_at":"2026-10-22T14:00:00Z",
    "identities":[{"provider":"apple","email":"relay@example.com","email_verified":true}]
  }
}
```

会话固定有效 7 天，退出后立即失效。客户端应保存到 Keychain，后续请求使用 PointVerse 的 access_token，而不是第三方 ID Token。过期需要再次第三方登录。

错误统一为 `{"error":{"code":"..."}}`：

| 状态码 | code | 含义 |
| --- | --- | --- |
| 400 | `invalid_request` | 请求格式、字段或挑战 ID 不符合协议 |
| 401 | `invalid_identity_token` | 凭证无效、重放、nonce 不匹配或挑战过期 |
| 401 | `unauthorized` | 当前会话缺失、已撤销或过期 |
| 415 | `json_required` | 登录请求必须使用 JSON |
| 429 | `rate_limited` | 暂时限流，附 `Retry-After: 60` |
| 503 | `provider_disabled` | 该登录渠道尚未配置 |
| 500 | `internal_error` | 存储操作失败，可稍后重试 |

## 账户边界与后续事项

- `(provider, sub)` 唯一定位身份。同一身份多次登录复用一个本地用户；Google 与 Apple 即使邮箱相同也创建不同用户。账户绑定与合并需要双方身份再次确认，本期未开放。
- 数据库仅保存会话 token 的 SHA-256、已使用身份令牌的规范化指纹，以及 Apple 挑战/nonce 的哈希；不保存第三方原始令牌。日志不输出令牌、请求体或身份 SQL 参数。
- 失效会话/令牌指纹在后续登录时分批清理，过期挑战在新挑战创建时清理。低活跃时期过期行仍可能保留，但不能用于认证。
- 当前限流为单进程内存实现，且不信任 `X-Forwarded-For`。正式部署在反向代理后时应增加明确的受信代理配置及共享限流。
- 本地会话撤销已完成；Google/Apple 在外部撤销授权不会自动撤销现有 PointVerse 会话。本期未实现服务商事件通知、Apple refresh token 状态复核、账户注销与第三方授权撤销；这些是正式发布登录功能前的后续工作。
- 不改变现有本地资料库，不要求离线记录必须登录，也不自动上传任何 Point 或附件。

## 验证

单元测试使用本地 RSA/JWKS 模拟服务验证真实签名校验逻辑，没有生产测试后门。完整测试使用独立临时 PostgreSQL schema，不写入实际账户：

```sh
TEST_DATABASE_URL='postgres://pointverse:pointverse_dev@localhost:5432/pointverse?sslmode=disable' go test -race -timeout 120s ./...
go vet ./...
```

测试覆盖错误签名/签发方/目标应用/有效期、Google 旧签发方兼容、Apple nonce 缺失、未配置渠道、限流、重复登录、并发首次登录、相同邮箱不同渠道、重放、过期会话与退出。真实 Google/Apple 授权仍需申请标识并配置 iOS SDK 后联调。
