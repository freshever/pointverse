#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
JDK=${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}
PLATFORM=${ANDROID_PLATFORM:-$(find "$SDK/platforms" -name android.jar | sort | tail -1)}
TOOLS=${ANDROID_BUILD_TOOLS:-$(find "$SDK/build-tools" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)}
OUT="$ROOT/app/build/local"
KEYSTORE=${POINTVERSE_DEBUG_KEYSTORE:-$ROOT/.signing/debug.keystore}
export JAVA_HOME="$JDK" PATH="$JDK/bin:$PATH"
"$ROOT/scripts/build-local.sh"
rm -rf "$OUT/test-classes" "$OUT/test-dex"
mkdir -p "$OUT/test-classes" "$OUT/test-dex"
cat > "$OUT/test-manifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pointverse.app.test">
<uses-sdk android:minSdkVersion="28" android:targetSdkVersion="35"/>
<application android:label="PointVerse Tests"><uses-library android:name="android.test.runner"/><uses-library android:name="android.test.base"/></application>
<instrumentation android:name="android.test.InstrumentationTestRunner" android:targetPackage="com.pointverse.app"/>
</manifest>
XML
OPTIONAL=$(dirname "$PLATFORM")/optional
"$TOOLS/aapt2" link -o "$OUT/test-unsigned.apk" --manifest "$OUT/test-manifest.xml" -I "$PLATFORM" -A "$ROOT/app/src/androidTest/assets"
"$JDK/bin/javac" --release 17 -classpath "$PLATFORM:$OPTIONAL/android.test.runner.jar:$OPTIONAL/android.test.base.jar:$OUT/classes" -d "$OUT/test-classes" "$ROOT"/app/src/androidTest/java/com/pointverse/app/*.java
"$JDK/bin/jar" cf "$OUT/test-classes.jar" -C "$OUT/test-classes" .
"$TOOLS/d8" --min-api 28 --lib "$PLATFORM" --lib "$OUT/classes.jar" --lib "$OPTIONAL/android.test.runner.jar" --lib "$OPTIONAL/android.test.base.jar" --output "$OUT/test-dex" "$OUT/test-classes.jar"
(cd "$OUT/test-dex" && zip -q -j "$OUT/test-unsigned.apk" classes*.dex)
"$TOOLS/zipalign" -f 4 "$OUT/test-unsigned.apk" "$OUT/test-aligned.apk"
"$TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --out "$OUT/pointverse-test.apk" "$OUT/test-aligned.apk"
# Tiny signed future-version APKs for updater verification; never installed.
python3 - "$ROOT/version.properties" "$OUT/update-fixture.xml" <<'PYFIXTURE'
import sys,pathlib,xml.etree.ElementTree as ET
version=dict(line.split('=',1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if '=' in line)
ns='http://schemas.android.com/apk/res/android';ET.register_namespace('android',ns)
root=ET.Element('manifest',{'package':'com.pointverse.app',f'{{{ns}}}versionCode':str(int(version['versionCode'])+1),f'{{{ns}}}versionName':'update-test'})
ET.SubElement(root,'uses-sdk',{f'{{{ns}}}minSdkVersion':'28',f'{{{ns}}}targetSdkVersion':'35'})
ET.SubElement(root,'application',{f'{{{ns}}}label':'点界更新测试',f'{{{ns}}}hasCode':'false'})
ET.ElementTree(root).write(sys.argv[2],encoding='utf-8',xml_declaration=True)
PYFIXTURE
"$TOOLS/aapt2" link -o "$OUT/update-fixture-unsigned.apk" --manifest "$OUT/update-fixture.xml" -I "$PLATFORM"
"$TOOLS/apksigner" sign --ks "$KEYSTORE" --ks-pass pass:android --out "$OUT/update-fixture.apk" "$OUT/update-fixture-unsigned.apk"
if [ ! -f "$OUT/update-untrusted.keystore" ]; then
    "$JDK/bin/keytool" -genkeypair -keystore "$OUT/update-untrusted.keystore" -storepass android -keypass android -alias untrusted -dname CN=UpdateTest -keyalg RSA -validity 3650 > /dev/null 2>&1
fi
"$TOOLS/apksigner" sign --ks "$OUT/update-untrusted.keystore" --ks-pass pass:android --out "$OUT/update-untrusted.apk" "$OUT/update-fixture-unsigned.apk"
"$SDK/platform-tools/adb" install -r "$OUT/pointverse-debug.apk"
"$SDK/platform-tools/adb" install -r "$OUT/pointverse-test.apk"
"$SDK/platform-tools/adb" shell pm grant com.pointverse.app android.permission.RECORD_AUDIO
"$SDK/platform-tools/adb" shell run-as com.pointverse.app mkdir -p files
"$SDK/platform-tools/adb" exec-in run-as com.pointverse.app sh -c 'cat > files/test-update.apk' < "$OUT/update-fixture.apk"
"$SDK/platform-tools/adb" exec-in run-as com.pointverse.app sh -c 'cat > files/test-update-untrusted.apk' < "$OUT/update-untrusted.apk"
"$SDK/platform-tools/adb" exec-in run-as com.pointverse.app sh -c 'cat > files/test-update-other-package.apk' < "$OUT/pointverse-test.apk"

if [ -f "$ROOT/.model-cache/vosk-model.zip" ]; then
    "$SDK/platform-tools/adb" shell run-as com.pointverse.app mkdir -p files
    "$SDK/platform-tools/adb" exec-in run-as com.pointverse.app sh -c 'cat > files/test-speech-model.zip' < "$ROOT/.model-cache/vosk-model.zip"
fi
# Android kills the calling app when this app-op is revoked. Restore it after the runner exits.
INSTALL_MODE=$("$SDK/platform-tools/adb" shell appops get com.pointverse.app REQUEST_INSTALL_PACKAGES | python3 -c 'import sys,re; m=re.search(r"REQUEST_INSTALL_PACKAGES: (allow|deny|ignore|default)",sys.stdin.read()); print(m[1] if m else "default")')
restore_install_mode() { "$SDK/platform-tools/adb" shell appops set com.pointverse.app REQUEST_INSTALL_PACKAGES "$INSTALL_MODE" >/dev/null 2>&1 || true; }
trap restore_install_mode EXIT
"$SDK/platform-tools/adb" shell appops set com.pointverse.app REQUEST_INSTALL_PACKAGES allow
if [ -n "${ANDROID_TEST_CLASS:-}" ]; then set -- -e class "$ANDROID_TEST_CLASS"; else set --; fi
"$SDK/platform-tools/adb" shell am instrument -w "$@" com.pointverse.app.test/android.test.InstrumentationTestRunner | tee "$OUT/test-results.txt"
python3 - "$OUT/test-results.txt" <<'PYTEST'
import pathlib,sys,re
result=pathlib.Path(sys.argv[1]).read_text()
if not re.search(r'OK \(\d+ tests?\)',result) or 'FAILURES' in result:
    raise SystemExit('Android instrumentation tests failed; inspect test-results.txt')
PYTEST
