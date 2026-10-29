#!/bin/bash
# Local Android SDK build; pinned offline speech dependencies are prepared separately.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
JDK=${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}
PLATFORM=${ANDROID_PLATFORM:-$(find "$SDK/platforms" -name android.jar | sort | tail -1)}
TOOLS=${ANDROID_BUILD_TOOLS:-$(find "$SDK/build-tools" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)}
OUT="$ROOT/app/build/local"
KEYSTORE=${POINTVERSE_DEBUG_KEYSTORE:-$ROOT/.signing/debug.keystore}
rm -rf "$OUT/classes" "$OUT/dex"
mkdir -p "$OUT/classes" "$OUT/dex"
export JAVA_HOME="$JDK"
export PATH="$JDK/bin:$PATH"
"$ROOT/scripts/prepare-speech.sh"
DEPS="$OUT/dependencies"
python3 - "$ROOT" "$OUT" <<'PY'
import sys,xml.etree.ElementTree as ET
from pathlib import Path
root,out=map(Path,sys.argv[1:]);ns='http://schemas.android.com/apk/res/android'
ET.register_namespace('android',ns)
version=dict(line.strip().split('=',1) for line in (root/'version.properties').read_text().splitlines() if line.strip() and not line.startswith('#'))
tree=ET.parse(root/'app/src/main/AndroidManifest.xml');m=tree.getroot();m.set('package','com.pointverse.app');m.set(f'{{{ns}}}versionCode',version['versionCode']);m.set(f'{{{ns}}}versionName',version['versionName'])
# Android parses application defaults using the SDK values already encountered.
# Keep uses-sdk before application, just as the Gradle manifest merger does.
m.insert(0,ET.Element('uses-sdk',{f'{{{ns}}}minSdkVersion':'28',f'{{{ns}}}targetSdkVersion':'35'}))
m.find('application').set(f'{{{ns}}}debuggable','true')
tree.write(out/'AndroidManifest.xml',encoding='utf-8',xml_declaration=True)
PY
"$TOOLS/aapt2" compile --dir "$ROOT/app/src/main/res" -o "$OUT/resources.zip"
"$TOOLS/aapt2" link -o "$OUT/unsigned.apk" --manifest "$OUT/AndroidManifest.xml" -I "$PLATFORM" -A "$ROOT/app/src/main/assets" "$OUT/resources.zip"
"$JDK/bin/javac" --release 17 -classpath "$PLATFORM:$DEPS/vosk.jar:$DEPS/jna.jar" -d "$OUT/classes" "$ROOT"/app/src/main/java/com/pointverse/app/*.java
"$JDK/bin/jar" cf "$OUT/classes.jar" -C "$OUT/classes" .
"$TOOLS/d8" --min-api 28 --lib "$PLATFORM" --output "$OUT/dex" "$OUT/classes.jar" "$DEPS/vosk.jar" "$DEPS/jna.jar"
(cd "$OUT/dex" && zip -q -j "$OUT/unsigned.apk" classes*.dex)
(cd "$DEPS/native" && zip -q -r "$OUT/unsigned.apk" lib)
"$TOOLS/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
mkdir -p "$(dirname "$KEYSTORE")"
if [ ! -f "$KEYSTORE" ] && [ -f "$OUT/debug.keystore" ]; then
    cp "$OUT/debug.keystore" "$KEYSTORE"
    chmod 600 "$KEYSTORE"
fi
if [ ! -f "$KEYSTORE" ]; then
    "$JDK/bin/keytool" -genkeypair -keystore "$KEYSTORE" -storepass android -keypass android -alias androiddebugkey -dname 'CN=Android Debug' -keyalg RSA -validity 10000 >/dev/null 2>&1
fi
"$TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --out "$OUT/pointverse-debug.apk" "$OUT/aligned.apk"
"$TOOLS/apksigner" verify "$OUT/pointverse-debug.apk"
echo "$OUT/pointverse-debug.apk"
