# PointVerse iOS POC

`PointVerseApp` 是单一 iPhone SwiftUI Target；`PointVerseKit` 承载领域、SQLite、Blob Store 和用例代码。

当前 P0 已包含：

- M4A/AAC、24kHz、单声道录音；
- staging 与 blob 位于同一目录树，音频以 rename 原子提交；
- SHA-256、相对路径与排除备份标记；
- GRDB v1 migration、WAL、外键与 FTS5；
- 同一 `operationId` 的事务幂等；
- 保存事实、Point 列表和模型占位状态界面。
- 简体中文、繁体中文、英文和日文界面与麦克风权限说明；Capture 同时持久化当前 locale，供 multilingual Whisper 使用。

原音播放器、系统设备端转写、失败重试、人工修正和全文搜索已经接入。精简版只使用 Apple Speech 的强制端侧模式；不再链接或下载 Whisper、Qwen、Qwen-VL 与 Stable Diffusion。系统转写不可用时保留原音并允许重试。

主界面包含“记录、星图、想法”三个入口。星图使用 SceneKit 展示稳定分布的 Point 节点，支持旋转、缩放、点选并打开详情；当前连线是布局提示，不作为持久化的语义关系。

尚未完成的 P0 工作是 staging 崩溃恢复与真机杀进程验收。Llama 属于 P2，不在当前骨架中伪实现。

## Apple Watch MVP

`PointVerseWatchApp` 是独立的 watchOS 10 捕获端，首版包含：

- 按住约 0.22 秒开始录音，松开保存，最长 60 秒；
- M4A/AAC、24kHz、单声道录音；
- 原音、SHA-256 与 `manifest.json` 先保存在 Watch；
- 最近 5 条记录及等待同步状态；
- 通过 WatchConnectivity `transferFile` 排队发送给配对 iPhone；
- 不链接 GRDB、Whisper、Qwen 或 Stable Diffusion。

生成工程：

```bash
cd ios
xcodegen generate
```

安装到真机：

1. iPhone 与 Apple Watch 完成配对，二者解锁并开启开发者模式。
2. 用数据线连接 iPhone；在 Xcode 的 `Window → Devices and Simulators` 确认 iPhone 与配对 Watch 均为 Ready。
3. 打开 `PointVerse.xcodeproj`，为 `PointVerse` 与 `PointVerseWatch` 选择同一个 Development Team。
4. 选择 `PointVerseWatch` scheme，并将运行设备选择为配对的 Apple Watch。
5. 点击 Run；Xcode 会通过配对 iPhone 安装并启动 Watch App。
6. 首次长按录音时，在手表上允许麦克风权限。

若 Watch 不出现在运行设备列表，先确认 Xcode 支持手表当前 watchOS 版本，再重新解锁、连接和配对设备。WatchConnectivity 的后台交付只能以真实配对设备作为验收依据。

当前 Watch 已排队发送文件，但 iPhone 端的幂等导入与业务回执属于下一批 W2/W3；在接收端完成前，Watch 会一直显示“等待同步”并保留本地原音。
