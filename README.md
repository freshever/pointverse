# 点界 PointVerse

PointVerse 正在按照核心语音 POC 文档迁移为 Swift / SwiftUI 原生 iPhone 应用。当前实现聚焦 P0：可靠完成“录音 → 原音落盘 → SQLite 事务成 Point → 重启后找回”。

## 原生 iOS

要求 Xcode 26 或更高版本。首次生成工程：

```bash
cd ios
xcodegen generate
open PointVerse.xcodeproj
```

命令行构建：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/PointVerse.xcodeproj \
  -scheme PointVerse -destination 'generic/platform=iOS Simulator' build
```

核心实现位于 `ios/PointVerseKit`，数据库使用 GRDB 7.10.0。Xcode 首次构建会解析该 Swift Package 依赖。

## H5 原型

旧版 H5 已整体移至 `h5/`，作为交互参考保留：

```bash
cd h5
npm run dev
```

POC 定义与技术方案位于 `docs/`。
