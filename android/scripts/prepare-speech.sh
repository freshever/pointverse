#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$ROOT/.deps"
fetch(){
    local file=$1 url=$2 expected=$3
    if [ ! -f "$file" ] || [ "$(shasum -a 256 "$file" | awk '{print $1}')" != "$expected" ]; then
        curl -fL --retry 2 --connect-timeout 15 --max-time 600 "$url" -o "$file.part"
        echo "$expected  $file.part" | shasum -a 256 -c -
        mv "$file.part" "$file"
    fi
}
fetch "$ROOT/.deps/vosk-runtime.aar" 'https://repo.maven.apache.org/maven2/com/alphacephei/vosk-android/0.3.75/vosk-android-0.3.75.aar' ab2f8b91ac8051561aa325546b35fed9a68b36b8121bac5c6fb927525c4adfad
fetch "$ROOT/.deps/jna-5.18.1.aar" 'https://repo.maven.apache.org/maven2/net/java/dev/jna/jna/5.18.1/jna-5.18.1.aar' 7f053e3ec99e14dd71259c82c1c8a02738d64a13c31226b2acc170f3060951e0
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys,zipfile,shutil
root=Path(sys.argv[1]);out=root/'app/build/local/dependencies';shutil.rmtree(out,ignore_errors=True);out.mkdir(parents=True,exist_ok=True)
for name,file in [('vosk','vosk-runtime.aar'),('jna','jna-5.18.1.aar')]:
 with zipfile.ZipFile(root/'.deps'/file) as archive:
  (out/(name+'.jar')).write_bytes(archive.read('classes.jar'))
  for entry in archive.namelist():
   if entry.startswith('jni/') and entry.endswith('.so') and entry.split('/')[1] in ['armeabi-v7a','arm64-v8a','x86','x86_64']:
    target=out/'native/lib'/Path(entry).relative_to('jni');target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(archive.read(entry))
PY
