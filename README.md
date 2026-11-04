# Side A

自用音乐播放器，当前 iPhone、Android 手机与车机版 **0.7.2**。包含 iPhone、Android 手机、安卓横屏车机客户端与统一曲库后台，采用毛玻璃界面、专辑封面和播放／歌词页。

## 功能

- 聚合搜索，以及「全部、QQ 音乐、网易云、酷我音乐、JOOX」分栏；结合歌名、歌手及版本信息排序。
- App 内播放、歌词、播放队列、收藏、自建歌单、最近播放和音质选择。
- 热歌、新歌与基于收藏、重听、听完、快速跳过等行为的个性推荐。接入独立 AI Hub 后，由所分配的模型分析有界行为摘要、对真实候选歌曲排序；模型未配置或不可用时保留本地规则推荐，播放不等待 AI。
- 封面、歌词等缓存及清理入口；应用不设固定磁盘缓存配额。流媒体播放缓冲不等同于完整歌曲离线下载。
- 统一后台保存 QQ 音乐登录状态，私有发行包自动连接，每台设备独立授权。
- 收藏、歌单、历史、偏好和播放设置自动备份；离线先存本地，联网后重试。
- 三端紧凑音效菜单：原声、立体环绕、音乐厅、清澈人声、录音棚、低音增强、柔和聆听；点选即收起，选择保存在本机并纳入设备备份。iOS 对 PCM 应用立体声扩展、房间混响或 EQ；Android 使用当前播放器的系统音效能力，不支持时继续原声。旧「通勤」迁移至「清澈人声」，旧「夜间」迁移至「柔和聆听」。
- 独立安卓车机版：横屏、左侧导航与歌曲封面 CD、全宽曲库和底部固定播放控制条。CD 随播放旋转，点击进入铺满内容区的同步歌词，左侧导航和底部播放控制始终保留；支持点击歌词定位。手机和车机使用不同应用标识与恢复身份。

音源返回的曲目、音质及可播放范围取决于上游接口、账号权限和网络；不保证所有歌曲均可播放或都有无损版本。原唱排序使用可获得的信息，不能保证准确识别每首歌的原唱。音频由手机直接访问来源 CDN，后台处理搜索、授权与资料同步。

## 目录

| 路径 | 内容 |
| --- | --- |
| `outputs/SideA/` | SwiftUI、AVFoundation iPhone 工程及 XCTest |
| `outputs/SideA-Android/` | Java 原生播放服务、WebView 界面、构建脚本及测试 |
| `outputs/SideA-Server/` | Flask、SQLite 统一后台，QQ／酷我适配器及受控回归测试 |
| `outputs/AI-Hub/` | 统一 AI 管理台、PostgreSQL 任务队列、LiteLLM 接口及 OECT Hermes 节点 |
| `outputs/安装 Side A 0.7.2 到 iPhone.command` | 配合已签名 IPA 使用的 Mac 安装工具 |

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
bash outputs/SideA-Android/build.sh outputs/SideA-0.7.2-Android.apk
SIDEA_VARIANT=car bash outputs/SideA-Android/build.sh outputs/SideA-0.7.2-Car.apk
```

车机包适用于可直接安装 APK、Android 9 或更新版本的设备；使用 `app/src/car/AndroidManifest.xml`，横屏界面按 800×480、1024×600、1280×720 和 1920×720 验证。具体车机的系统栏、屏幕密度、WebView 和音频硬件仍需真机确认。这是独立车机 APK，尚未实现 Android Auto 投屏或 AAOS 系统媒体入口。

0.6.1 修复旧版 WebView 在启动时遇到不支持的 JavaScript 语法、数组方法或媒体查询监听接口而无法显示界面的问题，并提供旧版 CSS 布局回退。界面完全使用 APK 内的资源，启动不等待在线曲库；原生加载层只在前端完成初始渲染后撤下。若界面仍无法启动，会显示重试入口及可复制的 Android／WebView 版本，不采集设备序列号、账户或听歌记录。升级沿用原有签名和恢复配置，可覆盖安装。

### 统一后台

后台支持 Python 3.12 与 Docker Compose。部署流程、私有安装授权格式、设备配对和备份接口详见 [后台说明](outputs/SideA-Server/README.md)。新主机示例：

```sh
cd outputs/SideA-Server
SIDEA_PUBLIC_BASE=https://music.example.com docker compose up -d --build
```

为该域名配置受手机信任的 HTTPS 反向代理，转发到 `127.0.0.1:18760`。后台使用单进程运行，以保留扫码登录的会话状态。后台账号、QQ 登录数据和每台设备的资料保存在私有服务数据目录中。

## 统一 AI 控制台

独立 [AI Hub](outputs/AI-Hub/README.md) 支持添加兼容 OpenAI 的接口、管理模型、查看调用状态，并按软件分配模型与额度。支持 Chat Completions 与 Responses；使用真实接口测试，不根据模型名称假定兼容。配置或更换模型不需要重打客户端。

Side A 服务端使用单独应用密钥连接 Hub，再依据已认证的设备恢复资料确定独立身份。客户端只上传最近 30 天的有界行为汇总与至多 60 首真实候选的元数据，AI 结果必须引用候选 ID。推荐缓存 6 小时，配置探测只在前台进行，不为每次播放发送模型请求。暂停、缓冲和播放失败不会作为快速跳过的负反馈。

腾讯云运行管理台、任务队列及普通模型调用；OECT 的独立 Hermes 节点通过出站 HTTPS 领取明确分配的任务，不需要家庭入站 80/443。节点使用每任务短期模型凭据，当前仅开放单轮文本分析，禁用个人记忆及工具。普通歌曲推荐不依赖家庭设备在线。

真实 AI 需要管理员配置有效服务商 API Key、模型和计费方式，并分配给软件；按量接口还需填写单价，已有订阅／固定费用模式只统计用量。源码不包含模型密钥或预置的免费模型；受控回归使用测试桩，不能替代真实接口验证。

## 测试

后台受控回归不需要真实 QQ 登录，使用临时目录和合成资料：

```sh
python3.12 -m venv work/server-venv
work/server-venv/bin/pip install -r outputs/SideA-Server/requirements.txt
(cd outputs/SideA-Server && ../../work/server-venv/bin/python -m unittest -v \
  test_server test_qq_provider test_kuwo_provider test_device_library test_ai_bridge)
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

车机界面回归使用合成桥接与封面，不连接生产后台。在仓库根目录执行（可用 `CHROME_PATH` 指定本机 Chrome）：

```sh
npm install --prefix work/car-redesign playwright@1.64.1
NODE_PATH="$PWD/work/car-redesign/node_modules" node outputs/SideA-Android/tests/car-layout/check.cjs
NODE_PATH="$PWD/work/car-redesign/node_modules" node outputs/SideA-Android/tests/car-layout/edge-check.cjs
```

覆盖四种横屏尺寸、歌词页保留导航、底栏位置一致、封面旋转、切歌、歌词定位、音效入口和手机界面回归。结果写入忽略的 `work/car-redesign/`。

旧内核回归见 [legacy-webview](outputs/SideA-Android/tests/legacy-webview/README.md)：使用真实 Chromium 67／V8 6.7，将 0.6.0 的启动空白与修复版进行对比，并检查搜索、歌词、音效及按钮位置。启动引导的独立测试可直接运行 `node outputs/SideA-Android/tests/legacy-webview/bootstrap.test.cjs`。原生加载层、重试和旧页面回调隔离另有 [startup instrumentation](outputs/SideA-Android/tests/startup/README.md)，仅允许在无凭据的 Android 模拟器上执行；本次已编译，尚未运行该仪器测试或用户的真实车机。

场景参数及降级逻辑的纯 Java 测试：`bash outputs/SideA-Android/tests/sound/run.sh`。模拟器测试探针提供 `mode=sound` 验证实际均衡器和音频播放，`mode=identity` 验证手机／车机恢复身份隔离；构建车机探针时设置 `SIDEA_TEST_TARGET=studio.sidea.car`。测试安装包使用合成恢复种子，不注入私人安装授权。

iOS 的 `SoundEffectsTests` 验证 PCM 频响、立体声、备份兼容和真实 AVPlayer tap。`SIDEA_SOUND_QA_BASE` 可启用本地合成 FLAC／MP3 的 HTTP 播放测试；`SIDEA_SOUND_QA_KUWO` 可启用指定公开酷我 CDN 的资源加载器测试。`SoundEffectsUITests` 检查选择持久化与设置可达性。

## 音效方案

评估了 [Media3](https://github.com/androidx/media)、[AudioKit](https://github.com/AudioKit/AudioKit) 与 [SoundpipeAudioKit](https://github.com/AudioKit/SoundpipeAudioKit)。本版沿用现有播放器，未复制这些项目的代码，也不需要 Root、系统音频捕获或额外音效 App。

- iOS 使用 [MTAudioProcessingTap](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtap)：环绕为保持声像中心的 M/S 扩展与 8ms 侧向反射；音乐厅／录音棚分别采用长／短房间的低通反馈延迟和扩散混响；人声／低音／柔和为 EQ。延迟缓存预分配，切换渐入，seek 清除尾音，预留增益余量。环绕要求双声道，房间效果支持单／双声道；不支持的格式旁路。
- Android 使用当前播放器 session 的 [Equalizer](https://developer.android.com/reference/android/media/audiofx/Equalizer)／[Virtualizer](https://developer.android.com/reference/android/media/audiofx/Virtualizer)，混响使用显式连接到本 MediaPlayer 的辅助效果。辅助引擎可能由系统共享，因此使用低控制优先级、控制权检查和失控断开；不对 session 0 使用全局插入效果，不修改系统音效设置。设备或当前输出路由不支持时会显示回退状态。

这些是立体声空间模拟和房间效果，不代表杜比授权、多声道输出或商业录音棚还原。不同设备的音频引擎响应可能不同；测试验证处理、衰减与稳定性，听感偏好仍取决于音乐和播放设备。原声用于直接保留录音。

Android 设备资料测试位于 `tests/device-backup/`，只允许在模拟器运行。使用与目标 APK 相同的签名构建测试 APK，再运行 `studio.sidea.cloudqa.CloudProbe` 的 `unit` 模式。涉及搜索、播放和重装恢复的集成测试需要独立测试设备及私有后台配置；不要对日常使用的资料库运行测试夹具。

## 数据恢复与维护

客户端先读取云端资料，再合并本地变更并上传，使用修订号处理并发冲突。每台设备的资料按授权隔离，音频缓存和临时播放链接不参与云备份。

重装恢复适用于同一设备、同一签名及仍有效的恢复凭据：iOS 使用本机 Keychain；Android 使用签名／用户范围内的设备标识与固定恢复种子。更换签名、恢复出厂设置、删除系统凭据或后台撤销设备后，不承诺自动找回旧资料。更新安装包时应保留原有签名及恢复配置。

服务端备份需同时保护 SQLite 数据库、密钥及发行包配置。对运行中的数据库使用 SQLite 在线备份 API，避免只复制主文件而遗漏 WAL。重新部署源码不会替代服务数据备份。

私有 IPA／APK 内含安装授权，只向授权使用者分发；不要上传为公开 Release 资产。项目未另行声明开源许可证，第三方依赖及素材的权利仍归各自权利人。
