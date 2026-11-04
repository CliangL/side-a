#!/bin/bash
# Emulator-only instrumentation; sign with the same certificate as the target Side A APK.
# Modes: unit, seed (0.4.4), upgrade, restore (after real uninstall), offline, conflict, sources.
# The restore fixture is saved in the target's external files as qa-evidence.json; preserve it on the host across uninstall.
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)/app/src/main"
: "${ANDROID_SDK_ROOT:?Set ANDROID_SDK_ROOT to the Android SDK directory}"
: "${JAVA_HOME:?Set JAVA_HOME to a JDK (17 or newer)}"
: "${SIDEA_KEYSTORE:?Set SIDEA_KEYSTORE to the PKCS12 signing keystore}"
: "${SIDEA_PASSWORD_FILE:?Set SIDEA_PASSWORD_FILE to a private file containing the signing password}"
out="${1:-SideA-device-backup-test.apk}"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
build_tools="$ANDROID_SDK_ROOT/build-tools/${SIDEA_BUILD_TOOLS:-36.0.0}"
platform="$ANDROID_SDK_ROOT/platforms/android-37.0/android.jar"
[[ -e "$platform" ]] || platform="$ANDROID_SDK_ROOT/platforms/android-37/android.jar"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sidea-build.XXXXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export PATH="$JAVA_HOME/bin:$PATH"
mkdir -p "$tmp"/{gen,classes,dex}
"$build_tools/aapt2" compile --dir "$src/res" -o "$tmp/res.zip"
"$build_tools/aapt2" link -I "$platform" --manifest "$src/AndroidManifest.xml" \
  --java "$tmp/gen" -A "$src/assets" "$tmp/res.zip" -o "$tmp/unsigned.apk"
find "$src/java" "$tmp/gen" -name '*.java' | while IFS= read -r file; do printf '"%s"\n' "$file"; done > "$tmp/sources"
javac --release 17 -encoding UTF-8 -classpath "$platform" -d "$tmp/classes" @"$tmp/sources"
jar cf "$tmp/program.jar" -C "$tmp/classes" .
"$build_tools/d8" --release --min-api 28 --lib "$platform" --output "$tmp/dex" "$tmp/program.jar"
(cd "$tmp/dex" && zip -q -0 "$tmp/unsigned.apk" classes*.dex)
"$build_tools/zipalign" -f 4 "$tmp/unsigned.apk" "$tmp/aligned.apk"
"$build_tools/apksigner" sign --ks "$SIDEA_KEYSTORE" --ks-key-alias "${SIDEA_KEY_ALIAS:-sidea}" \
  --ks-pass "file:$SIDEA_PASSWORD_FILE" --v4-signing-enabled false \
  --out "$tmp/signed.apk" "$tmp/aligned.apk"
"$build_tools/apksigner" verify --verbose --print-certs "$tmp/signed.apk"
"$build_tools/zipalign" -c 4 "$tmp/signed.apk"
cp "$tmp/signed.apk" "$out"
printf 'Signed installable APK: %s\n' "$out"
