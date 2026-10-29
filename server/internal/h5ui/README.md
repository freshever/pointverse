# 手机端 H5

生产入口：https://h5.dianjie.org/ 。公开页面部署在 VPS 独立目录，账户、录音文件、转写结果保存在 Mac 数据节点。

## 录音

`record.html` 支持 Safari/Chrome 的 MediaRecorder（优先 Opus WebM，Safari 使用 MP4），只在点击开始后请求麦克风。停止、切后台或离开页面会关闭麦克风；结束后可试听。浏览器不支持时可选择音频文件。离开或刷新页面不会保存临时录音，上传前可下载识别用 WAV。

最长 30 分钟，导入文件最多 100 MB、最多双声道。浏览器解码后转为单声道 PCM16 16 kHz WAV，每段不超过 120 秒，按顺序通过带同源 Cookie 的 `POST /web/ai/audio/transcriptions` 请求服务端选定的 Whisper 模型。分段结果在当前页面缓存，重试从失败片段继续；仅点击上传才发送音频，不使用浏览器厂商语音识别。停止等待只中止客户端请求；云端可能仍在结束本次识别。

识别结果可修改。点击保存后，将 WAV 上传到 `/web/sync/assets/{sha256}`，再提交 `/web/sync/points`。沿用手机格式版本 1 的快照结构，保留引擎识别文字与用户修正文字，云端想法页可查看、试听。上传按 SHA256 去重，保存重试复用相同 UUID 和序列化内容。提交未确认时暂不接受对该次提交的文字更改，避免不确定状态下生成不同版本。

录音识别本身使用临时文件；只有另行保存后才长期存储。接口沿用用户隔离、2 GiB 附件配额、同源 Origin 校验与私有模型网关凭据，供应商密钥不下发到浏览器。

## 发布与验证

```sh
node --test server/internal/h5ui/tests/*.test.mjs
bash server/deploy/update-web.sh alex@172.245.205.27 h5
```

发布将公用页面复制到独立 H5 发布包，加入手机导航，主站不随之发布。Go 浏览器转写与保存接口需要单独构建部署 Mac 后端。Caddy CSP 的 `media-src 'self' blob:` 用于本地试听及已保存音频播放。

运维实测脚本 `server/macmini/verify-h5-recording.py` 使用临时测试用户及合成语音，验证真实 Whisper 转写、音频与文字保存、重试去重、跨用户隔离，结束后删除本脚本创建的测试资料。

中文识别统一使用 OpenCC t2s 转为简体，分段文字同步处理，其他语言保持原样；响应仅在发生转换时附带 raw_text，保留模型原始字形输出。已保存的用户文字不做批量改写。
