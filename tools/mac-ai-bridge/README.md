# Mac AI GUI Bridge — Native POC

独立实验工程，不接入 PointVerse 生产服务。macOS 14+、Xcode Command Line Tools、Go 1.22+，无第三方依赖。

## 当前链路

客户端 → Go 本机协调器 → Swift Agent 主动拉取 → 新建 MockAI 原生进程 → Accessibility 填入 Prompt、按按钮、轮询答案 → ScreenCaptureKit 截取该进程窗口 → 结束进程 → 上传结果。

- 多用户令牌绑定身份；任务、答案和 PNG 均通过同一用户鉴权接口读取。
- 全局 FIFO 串行执行；Agent 不监听任何网络端口。
- 每个任务启动一个新进程；相同 `session_id` 也不保留历史。该字段目前只是客户端关联标签，不能当作持久对话。
- 截取提交后的界面和最终界面，PNG 以 base64 随结果返回；不截整个桌面，不写公共文件。提交后截图可能因系统捕获延迟已显示最终状态。
- 租约必须匹配才能完成任务。运行超时 60 秒后标记失败并停止分配，避免仍在执行的旧进程与新任务交叉。恢复时先停 Agent、确认 MockAI 已退出，再重启协调器及 Agent。
- 内存队列，重启丢失全部任务；最多保留 1000 个任务。尚无 JWT、SQLite、取消、自动重试、WebSocket、OCR 或视觉模型。

## 1. 编译与检查权限

在本目录运行：

```sh
swift build --package-path native
native/.build/debug/BridgeAgent --check
```

两个权限都需为 `true`。在系统设置 → 隐私与安全性中，为运行 Agent 的终端或 Agent 授予「辅助功能」和「屏幕与系统音频录制」权限，重启该终端后再检查。程序不会自动更改权限。需要已登录且未锁定的图形桌面会话。

若受限开发环境不能写默认编译缓存，可运行：

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/bridge-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/bridge-swift-cache \
swift build --disable-sandbox --package-path native
```

先做单任务 GUI 验证（输出含两张 PNG 的 JSON，请不要贴入公开日志）：

```sh
native/.build/debug/BridgeAgent --once '介绍一下 Mac GUI 自动化' > /tmp/bridge-result.json
```

模拟答案应为 `Mock answer: 介绍一下 Mac GUI 自动化`。这是确定性模拟器，不是真正的模型推理。

## 2. 启动协调器和 Agent

为两个用户和 Worker 分别生成随机令牌（各至少 24 字符）：

```sh
openssl rand -hex 32
```

终端 A，替换下列令牌后运行：

```sh
export BRIDGE_USERS='{"REPLACE_WITH_ALICE_RANDOM_TOKEN":"alice","REPLACE_WITH_BOB_RANDOM_TOKEN":"bob"}'
export BRIDGE_WORKER_TOKEN='REPLACE_WITH_SEPARATE_WORKER_RANDOM_TOKEN'
go run .
```

终端 B，设置相同的 Worker 令牌：

```sh
export BRIDGE_WORKER_TOKEN='REPLACE_WITH_SEPARATE_WORKER_RANDOM_TOKEN'
native/.build/debug/BridgeAgent
```

终端 C，使用 Alice 的令牌提交和查询：

```sh
export ALICE_TOKEN='REPLACE_WITH_ALICE_RANDOM_TOKEN'
curl -sS http://127.0.0.1:8088/tasks \
  -H "Authorization: Bearer $ALICE_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"session_id":"demo-1","prompt":"你好"}'

curl -sS http://127.0.0.1:8088/tasks/TASK_ID \
  -H "Authorization: Bearer $ALICE_TOKEN" > /tmp/bridge-task.json
```

查询返回 `queued`、`running`、`completed` 或 `failed`。完成后包含 `answer` 和 `screenshots.generating/final`；失败时查看 `error`，可能保留已捕获的截图。其他用户访问该任务会得到 404。

解码截图（单任务验证结果也适用）：

```sh
python3 - <<'PY'
import base64, json, pathlib
result = json.loads(pathlib.Path('/tmp/bridge-task.json').read_text())
for phase in ('generating', 'final'):
    data = result.get('screenshots', {}).get(phase)
    if data:
        target = pathlib.Path('/tmp') / (result['id'] + '-' + phase + '.png')
        target.write_bytes(base64.b64decode(data, validate=True))
        target.chmod(0o600)
        print(target)
PY
```

## 3. 远程调用边界

协调器固定绑定 `127.0.0.1:8088`。远端客户端通过 SSH 隧道访问，例如在客户端运行 `ssh -N -L 8088:127.0.0.1:8088 your-mac`，然后调用客户端本地端口。Agent 与协调器同机；本版 `BRIDGE_URL` 仅允许回环 HTTP 地址。没有公网监听、TLS 或公网部署配置。

令牌是 POC 的静态 bearer 凭据，不是 JWT；不要提交到版本库。协调器信任 Worker，Worker 令牌可以读取所有排队任务。已登录桌面上的其他本机进程仍可观察界面，本版不提供操作系统用户级隔离。

## 4. 验证与下一步

```sh
go test -race ./...
swift build --package-path native
```

Go 测试覆盖用户隔离、截图/答案访问控制、串行 FIFO、租约校验、重复完成、超时停止调度、身份伪造字段和输入校验。Swift 编译不代表 GUI 验证成功；完整验收还需在已授权的桌面执行 `--once`，再运行两用户任务并检查截图与答案。

下一阶段：持久化任务和会话映射、可恢复租约与 Agent 心跳、截图保留/清理、JWT；之后定义原生应用适配器（明确控件标识、完成信号、新对话/清理方法），再增加授权目标 App。当前 Agent 只启动同目录的 MockAI，不支持随请求指定任意进程或应用。真正多轮会话不能只靠复制 `session_id` 实现。

窗口截图使用 Apple [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(contentfilter:configuration:completionhandler:)) 的单窗口过滤器。

## ScreenProbe：通用只读窗口采集

原生 Swift 可执行程序，独立于电脑控制工具。编译后使用：

```sh
native/.build/debug/ScreenProbe --check
native/.build/debug/ScreenProbe --list
native/.build/debug/ScreenProbe --app com.example.app --window WINDOW_ID --output /tmp/screenprobe
```

`--list` 返回窗口 ID、应用 bundle ID 和标题。多个窗口时必须显式选择。每次采集新建 UUID 目录，包含 `window.png`、`accessibility.json`、`accessibility.txt`、`ocr.txt`、`metadata.json`。目录权限 700，文件 600。仅当 AX 窗口标题唯一匹配时导出该窗口树，避免读取其他窗口；无法匹配时仍可截取明确选定的窗口并 OCR。AX 最多遍历 3000 节点、30 层和约 10 秒（单次系统调用可能增加耗时）。OCR 使用系统 Vision，中英文识别，仅覆盖截图可见区域。不会上传数据，也不会点击、输入或发送消息。需已登录桌面和辅助功能、屏幕录制授权；当前是单次运行的命令行程序，尚未封装菜单栏 App 或常驻服务。

输入后模拟回车：

```sh
./screenprobe.sh --app com.openai.codex --confirmed-work-placeholder --type '终端输入并发送测试' --send
```

`--send` 仅在输入读回匹配（允许编辑器附加一个换行）且目标应用和输入框获得焦点时执行。它向目标进程发送 Return，是否真正提交由目标应用的回车设置决定；不代表已验证消息提交成功。省略该参数则只输入。请勿用于已有草稿的输入框。

更新：`--send` 现已改为通过 AXPress 点击发送按钮，不再模拟回车。默认匹配发送/发送消息/发送提示/Send/Send message/Send prompt，最多等待 30 秒，按钮必须启用且唯一。可用 `--buttons` 检查标签，再用 `--send-button '标签'` 指定。程序不会点击“停止”，日志中的按钮点击成功也不代表服务器已接收消息，仍需检查对话。

`--send` 点击发送后现会继续等待回复并采集窗口，保存到 `--output` 下的 UUID 子目录。最多等待 180 秒，以无“停止”按钮且新增 AXStaticText 稳定 5 秒作为完成启发式。新增静态文字去重写入 `answer.txt`，同时保存 `window.png`、`accessibility.json/txt` 和 `ocr.txt`。`answer.txt` 是候选回复，可能夹带新界面标签或遗漏与历史完全相同的文字；不是精确消息边界解析，OCR 也仅覆盖可见区域。多窗口请指定 `--window`。首次运行需实际验证目标应用的完成行为。

输入策略更新：按使用需求，`--type` 默认直接替换输入框内容，不再检查或依赖原有文字/占位符；`--confirmed-work-placeholder` 已不再需要。多个可写输入框时，优先唯一获得焦点的输入框，否则停止并提示先聚焦。此逻辑不能保证兼容所有应用，控件必须支持 AXValue 写入；发送按钮名称仍需按目标应用适配。
