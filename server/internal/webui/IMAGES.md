# 图片生成客户端

Web 入口为 `/account/images.html`，账户首页和云端想法页均有链接。登录后输入描述，生成 512×512 图片，可取消、下载；手机浏览器可长按保存。

浏览器只使用 `/web/` 下的 HttpOnly 登录 Cookie。创建、取消操作必须通过同源 Origin 检查；原生 `/v1/ai/` 接口继续只接受 Bearer Token。上游身份由服务端覆盖，图片任务仍按账户隔离。

Web 在 sessionStorage 中按账户记录描述、幂等 UUID 和任务编号；刷新或临时断网后恢复查询，丢失创建响应也复用同一 UUID。未登录不能访问生成接口；切换账户不读取前一账户的任务。云端结果保留 24 小时，客户端不自动上传到云端想法。

iOS 登录版默认使用 `pointverse-cloud` 图片路由。图片生成页与想法“显影”共用同一工作流，中文描述由服务端翻译，无需下载本地语言或图片模型。设置可切回已安装的本地图片模型；隐私版禁止云端调用。云端任务失败、取消或完成后清理本地恢复记录；网络错误保留幂等 UUID，相同描述重试可恢复查询。关闭生成页面会取消当前任务。

验证：

- `node --test server/internal/webui/tests/images.test.mjs`：断线恢复、取消和账户切换。
- Go `internal/ai`、`internal/auth`、`internal/webui`：固定转发目的地、身份覆盖、同源保护、页面资源。
- PointVerseKit `AccountAPITests`：任务请求和响应、隐私模式阻止请求。
- 运维 `server/macmini/verify-web-images.py`：创建临时测试账户和会话，通过公网 HTTPS 验证真实生图与隔离，最后撤销会话并删除测试账户。
