#!/usr/bin/env bash
set -euo pipefail

# Only public browser assets are deployed here. Accounts, uploads and AI stay on Mac.
task_root=$(cd "$(dirname "$0")/../.." && pwd)
task_target=${1:-alex@172.245.205.27}
task_variant=${2:-web}
[[ "$task_variant" == web || "$task_variant" == h5 ]] || { echo "variant must be web or h5" >&2; exit 1; }
task_temp=$(mktemp -d)
trap 'rm -rf "$task_temp"' EXIT
task_assets="$task_root/server/internal/webui/assets"
if [[ "$task_variant" == h5 ]]; then
  mkdir -p "$task_temp/assets/account"
  cp "$task_assets/"* "$task_temp/assets/account/"
  cp "$task_root/server/internal/h5ui/assets/"* "$task_temp/assets/"
  python3 - "$task_temp/assets/account" <<'PYTHON'
import pathlib, sys
nav = '<nav class="h5-nav" aria-label="主导航"><a href="/">首页</a><a href="/record.html">录音</a><a href="/account/library.html">想法</a><a href="/account/images.html">生图</a><a href="/account/">我的</a></nav>'
for page in pathlib.Path(sys.argv[1]).glob('*.html'):
    text = page.read_text().replace('</head>', '<link rel="stylesheet" href="/mobile.css"></head>')
    text = text.replace('</body>', nav + '</body>')
    text = text.replace('href="/account/" class="brand"', 'href="/" class="brand"').replace('class="brand" href="/account/"', 'class="brand" href="/"')
    text = text.replace('在手机上选中上传，在这里继续浏览。', '录音保存的想法与手机上传的内容，都在这里。')
    text = text.replace('在 iOS 登录同一账户，选中一条或多条想法上传后，会显示在这里。', '录音识别后保存，或在 iOS 上传想法后，会显示在这里。')
    page.write_text(text)
library_script = pathlib.Path(sys.argv[1]) / 'library.js'
library_script.write_text(library_script.read_text().replace('在 iOS 登录同一账户，选中一条或多条想法上传后，会显示在这里。', '录音识别后保存，或在 iOS 上传想法后，会显示在这里。'))
PYTHON
  task_assets="$task_temp/assets"
fi
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$task_temp/web.tgz" -C "$task_assets" .
task_digest=$(shasum -a 256 "$task_temp/web.tgz" | awk '{print $1}')
scp -q "$task_temp/web.tgz" "$task_target:/tmp/pointverse-web-$task_digest.tgz"
ssh "$task_target" bash -s -- "$task_digest" "$task_variant" <<'REMOTE'
set -euo pipefail
digest=$1
variant=$2
[[ "$variant" == web || "$variant" == h5 ]]
[[ "$digest" =~ ^[a-f0-9]{64}$ ]]
archive="/tmp/pointverse-web-$digest.tgz"
echo "$digest  $archive" | sha256sum -c -
root="/home/alex/pointverse/$variant"
mkdir -p "$root/releases/$digest"
tar -xzf "$archive" -C "$root/releases/$digest"
chmod -R u=rwX,go=rX "$root/releases/$digest"
ln -s "releases/$digest" "$root/current.next"
mv -Tf "$root/current.next" "$root/current"
rm "$archive"
echo "H5 static release activated: $digest"
REMOTE
