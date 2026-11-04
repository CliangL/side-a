#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mktemp -d "${TMPDIR:-/tmp}/sidea-sound-tests.XXXXXXXX")"
trap 'rm -rf "$out"' EXIT
if [[ -n "${JAVA_HOME:-}" ]]; then export PATH="$JAVA_HOME/bin:$PATH"; fi
javac --release 17 -d "$out" \
  "$root/app/src/main/java/studio/sidea/android/SoundPreset.java" \
  "$root/app/src/main/java/studio/sidea/android/SoundEffects.java" \
  "$root/tests/sound/SoundEffectsTest.java"
java -cp "$out" studio.sidea.android.SoundEffectsTest
