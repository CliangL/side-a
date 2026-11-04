#!/bin/bash
# Test-only org.json from Maven Central; never packaged in the APK.
set -euo pipefail
: "${JSON_JAR:?Set JSON_JAR to org.json json-20250517.jar}"
: "${JAVA_HOME:?Set JAVA_HOME to JDK 17 or newer}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mktemp -d "${TMPDIR:-/tmp}/sidea-ai-test.XXXXXXXX")"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$out"' EXIT
export PATH="$JAVA_HOME/bin:$PATH"
find "$root/tests/ai" -name '*.java' > "$out/sources"
printf '%s\n' "$root/app/src/main/java/studio/sidea/android/Json.java" "$root/app/src/main/java/studio/sidea/android/AIRecommendations.java" >> "$out/sources"
javac --release 17 -encoding UTF-8 -classpath "$JSON_JAR" -d "$out/classes" @"$out/sources"
java -cp "$out/classes:$JSON_JAR" studio.sidea.android.AIRecommendationTest
