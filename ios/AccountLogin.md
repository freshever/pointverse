# iOS 账户登录

入口：正式模式 → 模型 → 登录点界。账户不是启动门槛，未登录仍可记录与浏览本地资料；测试资料库不显示账户入口。登录不触发 Point、录音或图片上传。

## 已接入

- SwiftUI 账户页与 Google / Apple 官方按钮，加载、未开放、网络错误及重试状态。
- GoogleSignIn / GoogleSignInSwift 9.2.0，原生登录与 URL 回调。
- AuthenticationServices 原生 Apple 授权；先向服务端请求一次性挑战，将 nonce 原样传给 Apple，再提交 identityToken 与 challenge_id。
- 服务端会话查询、退出撤销、过期清理；Keychain 保存会话和服务地址绑定，凭证不写 UserDefaults。
- 账户接口独立在 PointVerseKit 的 AccountAPI 中，支持 Go 返回的带小数秒与不带小数秒日期，禁止认证请求跟随重定向。
- 简体中文、繁体中文、英文和日文文案。第三方官方按钮使用 SDK / 系统本地化。

## 开发环境

客户端固定连接 `https://dianjie.org`。账户页不提供服务地址设置，登录凭证只会发送到点界正式服务。

Docker 的 8090 端口已开放给局域网。真机输入 Mac 的局域网地址，例如 `http://192.168.3.4:8090`。设备需在同一网络。应用只开启 ATS 本地网络例外，没有全局禁用传输保护。

## 第三方配置

申请步骤与服务端接口协议见 [服务端账户文档](../server/AUTH.md)。目前未配置的渠道保持关闭；不包含模拟登录后门。

### 服务地址

账户 API 地址由客户端固定为 `https://dianjie.org`，无需额外构建设置。

### Google

在 PointVerse target build settings 中填写：

- `POINTVERSE_GOOGLE_CLIENT_ID`：iOS 类型 OAuth Client ID，Bundle ID 为 `org.dianjie.pv`。
- `POINTVERSE_GOOGLE_SERVER_CLIENT_ID`：后端使用的 Web 类型 Client ID。
- `POINTVERSE_GOOGLE_REVERSED_CLIENT_ID`：iOS Client ID 按点分隔倒序，例如 `123-abc.apps.googleusercontent.com` 对应 `com.googleusercontent.apps.123-abc`。

Info.plist 已使用这些设置填充 SDK 配置与 URL scheme。服务端的 GOOGLE_CLIENT_IDS 也要配置允许的 aud 与 azp。客户端同时确认服务端渠道已开启、本地 Client ID 及 URL scheme 完整，才开放 Google 按钮。

每次明确登录前会清理 Google SDK 本地旧登录状态，再进行交互授权，避免复用已兑换过的 ID Token。授权后只把 ID Token 发送给 PointVerse 服务。

### Apple

1. 在 Apple Developer 为 `org.dianjie.pv` 启用 Sign in with Apple。
2. 添加该 iOS target 的签名 entitlement：`com.apple.developer.applesignin` 为数组 `['Default']`，并在 project.yml 设置 `CODE_SIGN_ENTITLEMENTS` 指向该文件；重新生成工程和签名配置。
3. 将 `PointVerseApp/Info.plist` 中 `PointVerseAppleSignInEnabled` 改为 true。
4. 服务端配置 `APPLE_CLIENT_IDS=org.dianjie.pv`。

目前显式开关为 false，避免在尚未启用开发者能力时调起不可用授权。Apple 按钮须本地能力开关和服务端渠道同时开启。

## 状态和边界

- 重新进入账户页会查询服务端账户；网络不可用时保留尚未过期的本地会话，显示待验证状态。
- 退出成功后立即清除 Keychain 与客户端账户状态，保留所有本地记录。服务无法连接时明确提示联网重试，不宣称服务端会话已撤销。
- 当前未提供账号绑定、删除账户、浏览器 OAuth 流程或第三方撤权通知处理。
- 尚未申请 Client ID，真实授权、Keychain 真机持久化与签名能力仍需配置后联调。

## 验证

`swift test --package-path ios/PointVerseKit --filter AccountAPITests` 覆盖服务地址边界、请求字段和认证头、日期与会话编码、401 / 503 错误映射。

完整应用用真机目标进行编译验证。现有 llama.xcframework 不包含模拟器切片，因此账户页面可独立模拟器预览，完整应用暂不能直接以模拟器目标构建。

邮箱登录、单选/多选上传及网页展示见 [账户同步与网页展示](../docs/账户同步与网页展示.md)。
