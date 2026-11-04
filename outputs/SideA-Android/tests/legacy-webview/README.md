# Real old Chromium compatibility checks

This suite tests the **actual Chromium 67.0.3372.0 / V8 6.7.72 engine**, not a modern browser with a changed user agent. Node 22+ controls its original CDP protocol directly. `bridge.js` is ES5 and supplies synthetic library/player/search/lyrics data. No device ticket, account, production API, or actual music stream is used.

## Reproduce on macOS

Run commands from the repository root. On Apple Silicon, the downloaded Intel Chromium uses Rosetta.

1. Download the official Chromium snapshot [Mac/543305/chrome-mac.zip](https://storage.googleapis.com/chromium-browser-snapshots/Mac/543305/chrome-mac.zip) into `work/old-webview/543305.zip`. Expected size: 78,930,007 bytes; SHA-256: `3ea6002e6bb4406121ea1f7c36b8e28dea906a43bda5d4e48d887d74e6c671f1`.
2. Extract with `ditto -x -k work/old-webview/543305.zip work/old-webview/543305`. Preserve ZIP symlinks and executable permissions; Python's plain `extractall()` does not preserve these and cannot launch this bundle unchanged.
3. Prepare the old baseline from the original `SideA-0.6.0-Car.apk` into `work/old-webview/old`: only entries under `assets/` ending in `.html`, `.js`, `.css`, `.jpg`. Do **not** extract installation credentials or seed files. Alternatively use the unchanged assets from git tag `v0.6.0`.
4. Launch in its own terminal:

```sh
work/old-webview/543305/chrome-mac/Chromium.app/Contents/MacOS/Chromium \
  --headless --disable-gpu --no-sandbox --disable-background-networking \
  --remote-debugging-port=9227 --user-data-dir=work/old-webview/profile-67 \
  '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1' about:blank
```

5. In a second terminal: `node outputs/SideA-Android/tests/legacy-webview/server.cjs`
6. Run: `node outputs/SideA-Android/tests/legacy-webview/check.cjs`
7. Stop both owned test processes when finished. Do not use the old browser for ordinary web browsing.

`SIDEA_QA_CDP_PORT`, `SIDEA_QA_ORIGIN`, and `SIDEA_QA_OUTPUT` override CDP port, localhost server origin, and output folder. The server itself binds only `127.0.0.1:18771` and serves `/old`, `/new`, and `/phone` fixtures. The baseline root is `work/old-webview/old`; new UI comes directly from `app/src/main/assets`.

Optional static syntax guard (not a build dependency):

```sh
npm install --prefix work/old-webview/tools --no-audit --no-fund acorn@8.15.0
NODE_PATH="$PWD/work/old-webview/tools/node_modules" node outputs/SideA-Android/tests/legacy-webview/parse.cjs
```

This parses the startup bootstrap and synthetic bridge as ES5, and all other app scripts as ES2017.

## Assertions and evidence

- Baseline: navigation really loads `/old`, then `core.js` raises `SyntaxError`, body text remains empty, no car navigation buttons appear. A network failure is **not** accepted as the expected failure.
- Fixed assets: native readiness is called; car layouts at 800×480 and 1024×600 have no uncaught JS errors, offscreen controls, or dock/content overlap.
- Interactions: play/pause, next track, progress seek, CD to full lyrics with retained navigation, lyric seek, compact seven-preset sound menu and music hall selection, search results, and NetEase source selection.
- Phone at 390×844: opening the player shows a nonzero square album cover with the old `aspect-ratio` fallback.
- Screenshots and machine-readable report: `work/maintenance/release-061/legacy-webview-results.json` and adjacent PNGs.

This proves compatibility of the web UI with a real old engine. It does not emulate the user's unidentified head unit, Android media codecs, Java bridge, or native audio effects. A separate native startup/error-recovery instrumentation suite is provided. It was compiled, but not executed on an Android device or emulator in this verification.
