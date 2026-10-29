#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
apk=${1:-$root/android/app/build/local/pointverse-debug.apk}
target=${2:-alex@172.245.205.27}
notes=${3:-首个 Android 基础测试版：文字与语音记录、搜索、编辑、原音回放，接入点界账户及云端转写和整理。Android 9 真机与生产账户端到端验收待完成。}
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
tools=${ANDROID_BUILD_TOOLS:-$(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)}
export JAVA_HOME=${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
"$tools/apksigner" verify --print-certs "$apk" > "$temp/signature.txt"
"$tools/aapt" dump badging "$apk" > "$temp/badging.txt"
python3 - "$apk" "$temp" "$notes" <<'PY'
import datetime,hashlib,json,pathlib,re,shutil,sys
apk,folder=map(pathlib.Path,sys.argv[1:3]);notes=sys.argv[3]
meta=(folder/'badging.txt').read_text()
package=re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'",meta)
if not package or package[1]!='com.pointverse.app': raise SystemExit('Unexpected APK package')
minimum=int(re.search(r"sdkVersion:'(\d+)'",meta)[1])
if minimum!=28: raise SystemExit('This Android release must retain minSdk 28')
signer=re.search(r'Signer #1 certificate SHA-256 digest: ([a-fA-F0-9]+)',(folder/'signature.txt').read_text())[1].lower()
digest=hashlib.sha256(apk.read_bytes()).hexdigest(); version=package[3]
if not re.fullmatch(r'[A-Za-z0-9._-]+',version): raise SystemExit('Invalid versionName')
release={'package':package[1],'versionCode':int(package[2]),'versionName':version,'minSdk':minimum,'minAndroid':'9',
 'channel':'debug','file':f'pointverse-{version}-{package[2]}-debug-{digest[:12]}.apk','size':apk.stat().st_size,
 'sha256':digest,'signerSha256':signer,'publishedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'notes':notes}
(folder/'release.json').write_text(json.dumps(release,ensure_ascii=False,indent=2))
shutil.copyfile(apk,folder/'app.apk')
PY
cp "$root/server/android-downloads/"{index.html,downloads.css,downloads.js,caddy-route.txt} "$temp/"
cp "$root/server/deploy/android-release.py" "$temp/"
remote=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$target" 'mktemp -d /tmp/pointverse-android.XXXXXXXX')
[[ "$remote" =~ ^/tmp/pointverse-android\.[A-Za-z0-9]+$ ]]
# Seed the incoming APK from the previous release so rsync only sends changed blocks.
if command -v rsync >/dev/null && ssh "$target" 'command -v rsync >/dev/null'; then
  ssh "$target" python3 - "$remote" <<'SEED'
import json,pathlib,shutil,sys
root=pathlib.Path('/home/alex/pointverse/web/android')
base=pathlib.Path('/home/alex/pointverse/tools/android-transfer-base.apk')
if (root/'releases.json').is_file():
    manifest=json.loads((root/'releases.json').read_text());previous=root/'files'/manifest['latest']
    if previous.is_file() and (not base.is_file() or previous.stat().st_size>base.stat().st_size):base=previous
if base.is_file():shutil.copyfile(base,pathlib.Path(sys.argv[1])/'app.apk')
SEED
  rsync -a --partial "$temp/app.apk" "$target:$remote/app.apk"
else
  scp -q "$temp/app.apk" "$target:$remote/app.apk"
fi
scp -q "$temp/"{release.json,index.html,downloads.css,downloads.js,caddy-route.txt,android-release.py} "$target:$remote/"
ssh "$target" bash -s -- "$remote" <<'REMOTE'
set -euo pipefail
incoming=$1
trap 'rm -rf "$incoming"' EXIT
root=/home/alex/pointverse/web/android
python3 "$incoming/android-release.py" --root "$root" --incoming "$incoming"
# Management tool lives outside the public web root.
mkdir -p /home/alex/pointverse/tools
install -m 0755 "$incoming/android-release.py" /home/alex/pointverse/tools/android-release.py
python3 - "$incoming/caddy-route.txt" "$incoming/caddy-original" <<'PY'
import pathlib,sys
config=pathlib.Path('/home/alex/pointverse/server/Caddyfile.native')
text=config.read_text()
pathlib.Path(sys.argv[2]).write_text(text)
if '# BEGIN POINTVERSE ANDROID DOWNLOADS' not in text:
    if not text.startswith('dianjie.org {\n'): raise SystemExit('Unexpected Caddy configuration; refusing to patch')
    backup=config.with_name('Caddyfile.before-android')
    if not backup.exists(): backup.write_text(text); backup.chmod(0o600)
    # In-place write preserves the inode of the existing Docker bind mount.
    config.write_text(text.replace('dianjie.org {\n','dianjie.org {\n'+pathlib.Path(sys.argv[1]).read_text(),1))
PY
if ! docker exec pointverse-caddy-1 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || ! docker exec pointverse-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  echo 'Caddy validation failed; restoring previous config' >&2
  python3 - "$incoming/caddy-original" <<'PY'
from pathlib import Path
import sys
p=Path('/home/alex/pointverse/server/Caddyfile.native');p.write_text(Path(sys.argv[1]).read_text())
PY
  docker exec pointverse-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true
  exit 1
fi
# Add an entry point while preserving all currently deployed account assets.
python3 - <<'PY'
import hashlib,os,pathlib,shutil,tempfile
root=pathlib.Path('/home/alex/pointverse/web');current=(root/'current').resolve();page=current/'index.html'
text=page.read_text()
if '/downloads/android/' not in text:
    anchor='<p><a class="gallery-link" href="/downloads/android/">下载 Android 测试版 →</a></p>'
    marker='<div class="privacy-note">'
    if marker not in text: raise SystemExit('Account page marker missing; download URL is already live')
    stage=pathlib.Path(tempfile.mkdtemp(prefix='android-nav-',dir=root/'releases'))
    shutil.copytree(current,stage,dirs_exist_ok=True)
    (stage/'index.html').write_text(text.replace(marker,anchor+'\n      '+marker,1))
    digest=hashlib.sha256()
    for file in sorted(stage.rglob('*')):
        if file.is_file(): digest.update(str(file.relative_to(stage)).encode());digest.update(file.read_bytes())
    release=root/'releases'/digest.hexdigest()
    if release.exists(): shutil.rmtree(stage)
    else: stage.rename(release)
    link=root/'current.android-next';link.symlink_to(release.relative_to(root));os.replace(link,root/'current')
PY
echo 'Android download page: https://dianjie.org/downloads/android/'
REMOTE
