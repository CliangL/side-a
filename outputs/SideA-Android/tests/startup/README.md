# Native startup regression

`StartupProbe` validates the actual Android WebView bridge and native recovery overlay. It covers readiness only after a JavaScript handshake, no player update before readiness, strict bundled-resource access, renderer failure, fresh-WebView retry, stale callback isolation, timeout recovery, and sanitized compatibility details.

Use a fresh Android SDK emulator and a QA APK built **without** `SIDEA_SETUP_FILE` or `SIDEA_RECOVERY_FILE`. The probe refuses real devices, enrolled installations, personal libraries, and private distribution APKs. It disables automatic enrollment and substitutes a local page before the first UI event turn; no music, account, or backup endpoints are requested. It does not test the packaged frontend rendering; that is covered by the web compatibility tests.

Build the car QA app and this probe with the same signing certificate:

```sh
SIDEA_VARIANT=car bash outputs/SideA-Android/build.sh /absolute/path/SideA-Car-QA.apk
bash outputs/SideA-Android/tests/startup/build.sh /absolute/path/SideA-startup-test.apk
adb -s emulator-5554 install /absolute/path/SideA-Car-QA.apk
adb -s emulator-5554 install /absolute/path/SideA-startup-test.apk
adb -s emulator-5554 shell am instrument -w studio.sidea.bootqa/studio.sidea.bootqa.StartupProbe
```

The test reports `result=PASS` when complete. Use a new emulator installation for each run because the safety check requires empty settings. `SIDEA_TEST_TARGET=studio.sidea.android` builds the same probe for a fresh phone QA app. No emulator image is downloaded by these scripts.
