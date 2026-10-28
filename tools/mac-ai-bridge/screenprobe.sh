#!/bin/bash
set -euo pipefail
BRIDGE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export CLANG_MODULE_CACHE_PATH="$BRIDGE_DIR/native/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BRIDGE_DIR/native/.build/swift-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
BRIDGE_BIN_DIR="$BRIDGE_DIR/native/.build/debug"
# Keep the approved executable unchanged during requests: rebuilding can revoke
# macOS Accessibility permission for an unsigned executable.
if [[ ! -x "$BRIDGE_BIN_DIR/ScreenProbe" ]]; then
  swift build --package-path "$BRIDGE_DIR/native" --product ScreenProbe >&2
fi
if [[ $# -eq 0 ]]; then
  cat <<'HELP'
ScreenProbe — Mac 界面采集与输入测试

用法：
  ./screenprobe.sh --check
  ./screenprobe.sh --list
  ./screenprobe.sh --app APP_BUNDLE_ID --window WINDOW_ID --output /tmp/screenprobe
  ./screenprobe.sh --app APP_BUNDLE_ID --type '测试文字' [--send]

当前 ChatGPT 输入测试（会替换输入框现有内容）：
  ./screenprobe.sh --app com.openai.codex --type '终端自动输入测试'

加 --send 会在输入校验和焦点检查通过后点击发送按钮；不加则不发送。
等待发送按钮最多 30 秒；可用 --buttons 查看按钮，--send-button 名称 指定标签。默认替换现有输入内容；多个输入框时请先点击目标聊天输入框。
首次运行可能需要在系统设置中给终端开启辅助功能、屏幕录制权限。
HELP
  exit 0
fi
exec "$BRIDGE_BIN_DIR/ScreenProbe" "$@"
