# 点界 PointVerse H5

点界的首轮 H5 交互原型。当前目标是验证“对话成点 → 3D 空间找回 → Play → 行动与反馈”的产品闭环。H5 通过本地 JSON API 使用 SQLite，客户端不直接绑定数据库驱动。

## 本地运行

需要 Node.js 18 或更高版本，不需要安装第三方依赖。

```bash
npm run dev
```

打开 <http://127.0.0.1:4173>。

## 检查

```bash
npm run check
```

## 当前边界

- Point 和文本消息保存在 `data/pointverse.sqlite`，刷新后可恢复。
- 图片附件目前仍只保留在当前页面内。
- 不调用真实模型，不上传内容。
- 语音、分享和外部执行均为流程演示。
- `product.docx` 是产品定义，`backlog.md` 是实施与验收清单。

## 目录

```text
.
├── index.html        H5 应用入口
├── interact.html     v0.8 原始交互线框备份
├── src/              H5 样式、交互、API 客户端与 SQLite 数据层
├── data/             本地 SQLite 数据文件（不提交版本库）
├── scripts/          无依赖开发服务器与检查脚本
├── product.docx      产品文档
└── backlog.md        产品 Backlog
```
