# Side A

自用音乐播放器，当前客户端版本 **0.5.0**。包含 iPhone、Android 手机、安卓横屏车机客户端与统一曲库后台，采用毛玻璃界面、专辑封面和播放／歌词页。

## 功能

- 聚合搜索，以及「全部、QQ 音乐、网易云、酷我音乐、JOOX」分栏；结合歌名、歌手及版本信息排序。
- App 内播放、歌词、播放队列、收藏、自建歌单、最近播放和音质选择。
- 热歌、新歌与基于收藏、重听、听完、快速跳过等行为的个性推荐。当前推荐由规则与音乐元数据驱动，未接入大语言模型。
- 封面、歌词等缓存及清理入口；应用不设固定磁盘缓存配额。流媒体播放缓冲不等同于完整歌曲离线下载。
- 统一后台保存 QQ 音乐登录状态，私有发行包自动连接，每台设备独立授权。
- 收藏、歌单、历史、偏好和播放设置自动备份；离线先存本地，联网后重试。
- 三端场景音效：原声、人声、低音、舒缓、通勤、夜间；选择保存在本机并纳入设备备份。iOS 对解码后的 PCM 使用音频处理 tap，Android 使用当前播放器会话的 Equalizer，包含增益余量及不可用时的原声回退。夜间为柔和 EQ，不是响度压缩。
- 独立安卓车机版：横屏、左侧导航、中间曲库、右侧常驻播放区，大按钮及简化层级。手机和车机使用不同应用标识与恢复身份。

音源返回的曲目、音质及可播放范围取决于上游接口、账号权限和网络；不保证所有歌曲均可播放或都有无损版本。原唱排序使用可获得的信息，不能保证准确识别每首歌的原唱。音频由手机直接访问来源 CDN，后台处理搜索、授权与资料同步。

## 目录

| 路径 | 内容 |
| --- | --- |
| `outputs/SideA/` | SwiftUI、AVFoundation iPhone 工程及 XCTest |
| `outputs/SideA-Android/` | Java 原生播放服务、WebView 界面、构建脚本及测试 |
| `outputs/SideA-Server/` | Flask、SQLite 统一后台，QQ／酷我适配器及受控回归测试 |
| `outputs/安装 Side A 0.5.0 到 iPhone.command` | 配合已签名 IPA 使用的 Mac 安装工具 |

仓库仅保存源码、文档和必要工具。私有安装包、签名材料、安装授权、设备恢复种子、个人数据及临时构建目录不提交 Git。

## 构建

### iPhone

需要 macOS、Xcode 和 iOS 18 或更新的 SDK。打开 `outputs/SideA/SideA.xcodeproj`，选择 `SideA` scheme。安装到真机前，在 Signing & Capabilities 中选择自己的开发团队并配置有效签名。

模拟器构建：

```sh
xcodebuild -project outputs/SideA/SideA.xcodeproj -scheme SideA \
  -configuration Debug -sdk iphonesimulator \
  -derivedDataPath work/ios-build CODE_SIGNING_ALLOWED=NO build
```

使用统一后台时，将 `CentralServer.swift` 中的 `personalBase` 配置为自己的 HTTPS 后台；私有发行包在签名前将授权文件作为 `SideASetup.txt` 注入 App 资源。授权文件不进入源码提交。

工程另有 `SideA-CarPlay` scheme。真机 CarPlay 需要 Apple 批准的音频 entitlement 及相应描述文件；普通自用签名包不因此自动获得 CarPlay 权限。

### Android

需要 JDK 17 或更新版本、Android SDK Platform 37（支持目录名 `android-37.0` 或 `android-37`）及 Build Tools 36.0.0。最低系统 API 为 28。项目直接使用官方 SDK 工具构建，不使用 Gradle。

先配置以下环境变量：

| 变量 | 用途 |
| --- | --- |
| `ANDROID_SDK_ROOT` | Android SDK 路径 |
| `JAVA_HOME` | JDK 路径 |
| `SIDEA_KEYSTORE` | 私有 PKCS12 签名文件 |
| `SIDEA_PASSWORD_FILE` | 仅本机可读的签名密码文件 |
| `SIDEA_KEY_ALIAS` | 可选，默认 `sidea` |
| `SIDEA_BUILD_TOOLS` | 可选，默认 `36.0.0` |
| `SIDEA_SETUP_FILE` | 私有发行包的安装授权文件 |
| `SIDEA_RECOVERY_FILE` | 私有发行包的持久恢复种子文件 |

使用统一后台时，将 `CentralCatalog.java` 中的 `PERSONAL_BASE` 配置为自己的 HTTPS 地址。`SIDEA_SETUP_FILE` 与 `SIDEA_RECOVERY_FILE` 在构建时注入 APK；恢复种子应独立保管，并在后续版本中保持不变。

```sh
bash outputs/SideA-Android/build.sh outputs/SideA-0.5.0-Android.apk
SIDEA_VARIANT=car bash outputs/SideA-Android/build.sh outputs/SideA-0.5.0-Car.apk
```

车机包适用于可直接安装 APK、Android 9 或更新版本的设备；使用 `app/src/car/AndroidManifest.xml`，横屏界面按 800×480、1024×600、1280×720 和 1920×720 验证。具体车机的系统栏、屏幕密度、WebView 和音频硬件仍需真机确认。这是独立车机 APK，尚未实现 Android Auto 投屏或 AAOS 系统媒体入口。

### 统一后台

后台支持 Python 3.12 与 Docker Compose。部署流程、私有安装授权格式、设备配对和备份接口详见 [后台说明](outputs/SideA-Server/README.md)。新主机示例：

```sh
cd outputs/SideA-Server
SIDEA_PUBLIC_BASE=https://music.example.com docker compose up -d --build
```

为该域名配置受手机信任的 HTTPS 反向代理，转发到 `127.0.0.1:18760`。后台使用单进程运行，以保留扫码登录的会话状态。后台账号、QQ 登录数据和每台设备的资料保存在私有服务数据目录中。

## 测试

后台受控回归不需要真实 QQ 登录，使用临时目录和合成资料：

```sh
python3.12 -m venv work/server-venv
work/server-venv/bin/pip install -r outputs/SideA-Server/requirements.txt
(cd outputs/SideA-Server && ../../work/server-venv/bin/python -m unittest -v \
  test_server test_qq_provider test_kuwo_provider test_device_library)
```

iOS 单元测试及搜索／设置界面测试（将模拟器 ID 替换为本机可用设备）：

```sh
xcodebuild -project outputs/SideA/SideA.xcodeproj -scheme SideA \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' \
  -derivedDataPath work/ios-tests CODE_SIGNING_ALLOWED=NO \
  -only-testing:SideATests -only-testing:SideAUITests/CatalogFilterTests \
  -only-testing:SideAUITests/SoundEffectsUITests test
```

Android 来源标签回归：

```sh
node outputs/SideA-Android/tests/source-label.test.cjs
```

场景参数及降级逻辑的纯 Java 测试：`bash outputs/SideA-Android/tests/sound/run.sh`。模拟器测试探针提供 `mode=sound` 验证实际均衡器和音频播放，`mode=identity` 验证手机／车机恢复身份隔离；构建车机探针时设置 `SIDEA_TEST_TARGET=studio.sidea.car`。测试安装包使用合成恢复种子，不注入私人安装授权。

iOS 的 `SoundEffectsTests` 验证 PCM 频响、立体声、备份兼容和真实 AVPlayer tap。`SIDEA_SOUND_QA_BASE` 可启用本地合成 FLAC／MP3 的 HTTP 播放测试；`SIDEA_SOUND_QA_KUWO` 可启用指定公开酷我 CDN 的资源加载器测试。`SoundEffectsUITests` 检查选择持久化与设置可达性。

## 音效方案

评估了 [Media3](https://github.com/androidx/media)、[AudioKit](https://github.com/AudioKit/AudioKit) 和 [RootlessJamesDSP](https://github.com/timschneeb/RootlessJamesDSP)。本版使用现有播放器的系统处理接口与自行实现的场景参数，无需 Root、系统音频捕获或额外音效 App，未引入上述项目的代码。Android 使用 [AudioEffect / Equalizer](https://developer.android.com/reference/android/media/audiofx/Equalizer)，iOS 使用 [MTAudioProcessingTap](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtap)。预设名称一致，不保证不同设备的频带响应完全相同；界面只在实际处理成功后显示启用状态。

Android 设备资料测试位于 `tests/device-backup/`，只允许在模拟器运行。使用与目标 APK 相同的签名构建测试 APK，再运行 `studio.sidea.cloudqa.CloudProbe` 的 `unit` 模式。涉及搜索、播放和重装恢复的集成测试需要独立测试设备及私有后台配置；不要对日常使用的资料库运行测试夹具。

## 数据恢复与维护

客户端先读取云端资料，再合并本地变更并上传，使用修订号处理并发冲突。每台设备的资料按授权隔离，音频缓存和临时播放链接不参与云备份。

重装恢复适用于同一设备、同一签名及仍有效的恢复凭据：iOS 使用本机 Keychain；Android 使用签名／用户范围内的设备标识与固定恢复种子。更换签名、恢复出厂设置、删除系统凭据或后台撤销设备后，不承诺自动找回旧资料。更新安装包时应保留原有签名及恢复配置。

服务端备份需同时保护 SQLite 数据库、密钥及发行包配置。对运行中的数据库使用 SQLite 在线备份 API，避免只复制主文件而遗漏 WAL。重新部署源码不会替代服务数据备份。

私有 IPA／APK 内含安装授权，只向授权使用者分发；不要上传为公开 Release 资产。项目未另行声明开源许可证，第三方依赖及素材的权利仍归各自权利人。
