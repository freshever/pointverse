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

原音播放器、系统设备端转写、失败重试、人工修正和全文搜索已经接入。当前以 Apple Speech 的强制端侧模式先形成基本闭环；Whisper runtime 仍按 P1 计划接入，用于不依赖系统语言包的完全离线能力。

尚未完成的 P0 工作是 staging 崩溃恢复与真机杀进程验收。Llama 属于 P2，不在当前骨架中伪实现。
