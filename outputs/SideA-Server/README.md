# Side A 统一后台

自用版 0.4.2 及更新的 iPhone 和安卓安装包首次联网会自动连接 https://music.cliang.top/ 。每台设备拥有独立的访问令牌。已有配对继续使用。旧版客户端可继续使用管理员生成的一次性配对码。

0.4.3 起，在 App 的「搜索曲库」选择「QQ 音乐」可单独搜索后台的 QQ 曲库。选择「统一曲库」会搜索后台启用的所有来源。搜索接口支持可选的 `provider=qq` 参数，播放、封面和歌词继续使用搜索结果原有的曲目标识。

0.4.5 的搜索分栏提供全部、QQ 音乐、网易云、酷我音乐和 JOOX，分别使用聚合搜索及 `qq`、`wy`、`kw`、`jx` 过滤器。酷我通过公开接口查询，并验证 MP3 响应的实际码率和时长。酷我 CDN 要求官网 Referer 与普通 User-Agent，由手机直接请求音频时提供。来源没有返回可验证的完整录音时，播放器保留实际失败状态。

## 自用安装包

自动配对只对配置了安装授权的私有发行包开放。取得安装包的人可以使用其剩余名额。当前每个平台各允许八台同时授权的设备。在后台可以暂停接纳新设备，或单独撤销设备。撤销后释放一个名额，同一安装不能自行恢复授权。

自建部署时，每个私有发行包使用由 32 个随机字节生成的无填充 URL-safe Base64 授权。安装包单独注入纯文本资源 `SideASetup.txt`。在服务数据目录添加 `private-builds.json`，内容是 JSON 数组，各项包含 `ticket_hash`（授权字符串的 SHA-256 十六进制摘要）与 `device_limit`（1 到 100）。修改此文件后重启服务。保存数据目录中的 `enrollment-key` 和数据库，可以在重复请求和升级后维持设备授权。

## 每台设备的独立资料

0.4.5 增加设备独立云备份。客户端为本机保存私有恢复凭据，服务器只存凭据的 SHA-256 摘要。收藏、歌单、播放历史和推荐偏好由客户端保存为独立的 JSON 文档，每台设备独立授权和独立修订号。音频缓存与临时播放直链不进入备份。数据库采用同一个 SQLite 文件中的逻辑隔离，各设备接口只能访问自己的资料。

客户端首先使用设备 Bearer 授权调用 `POST /v1/library/bind`，JSON 为 `{"recovery":"64位小写十六进制凭据","platform":"ios或android"}`。绑定返回 `{"revision":0,"data":null}` 或已有文档。相同凭据可在同平台重装后恢复，恢复成功会退役该资料先前的设备授权。当前设备不能重新绑定另一份资料，后台撤销设备会永久阻止其恢复凭据再次连接。

`POST /v1/enroll` 保持兼容，额外接受可选且必须同时出现的 `recovery` 和 `platform`。已存在且未被撤销的资料，可以在设备名额已满或暂停新设备时恢复。恢复和退役旧授权属于同一事务，不额外占用名额。未知凭据仍遵守通常的安装名额和新设备开关。已撤销或已退役的旧 installation 不能重新加入。

绑定后，`GET /v1/library` 返回 `{"revision":整数,"data":JSON对象或null}`。`PUT /v1/library` 提交 `{"revision":读取到的整数,"data":JSON对象}`，成功时返回最新文档及修订号。并发写入冲突返回 HTTP 409 与当前文档，客户端必须合并后重试。内容相同且修订号为当前值或前一版的重复请求不会增加修订号。此 PUT 的请求体上限为 4 MiB，其他接口保持 16 KiB。数据大小限制只约束同步请求，不影响手机音频缓存容量。接口不接受指定其他设备或资料的查询参数。

云备份记录位于 `control.sqlite3` 的 `library_profiles` 和 `library_devices` 表。备份服务器时，使用 SQLite 在线备份 API 或停止服务后复制数据库，不能只复制运行中的主文件而遗漏 WAL。另行保护 `enrollment-key`、其他服务密钥和私有发行包配置，并将备份保存在独立位置。仅部署新版源代码不会替换这些数据。

## 账号与曲库

在后台选择「用手机 QQ 扫码」或「用 QQ 音乐扫码」，用对应的 App 扫描并确认。选择 QQ 音乐时，先在 QQ 音乐里登录你想绑定的账号。手机确认后，后台还要接收并保存授权，页面显示「已连接」才算完成。切回浏览器可以继续查看同一次扫码的结果。账号授权仅用于自己已配对的设备。登录过期且续期失败时回到此页重新扫码。

管理员可以撤销设备、调整来源顺序、启停来源，也能添加兼容 GD 的 HTTPS 接口。保存后，设备下次搜索或取播放地址会使用新配置。

iOS 和 Android 自行播放音源返回的 HTTPS 地址。服务器不转发音频，也不存储云端曲目的临时直链。如果来源要求会员、限制设备或网络位置，播放器显示实际错误。QQ 接口基于第三方 qqmusic-api-python，其稳定性和可用范围取决于上游。

## 在新主机上部署

可使用 Python 3.12 venv 与 Waitress 单进程多线程，或项目内的 Docker Compose。反向代理需提供手机系统信任的 HTTPS 证书，应用服务监听本机。多进程会使正在等待扫码的登录状态分散在不同进程，请使用单个进程。

使用 Docker Compose 时，在此目录运行：

```sh
SIDEA_PUBLIC_BASE=https://music.cliang.top docker compose up -d --build
docker compose exec controller cat /data/admin-password
```

将该域名反向代理至 127.0.0.1:18760。使用专用的子路径部署时，把 SIDEA_PUBLIC_BASE 改为包括子路径的完整 HTTPS 地址，并让反向代理在转发前移除这个路径前缀。

后台在数据目录首次生成管理员密码。只在本机或通过已验证的 SSH 读取。备份时保护整个私有数据目录，包括设备授权哈希、QQ 加密登录数据及其主密钥。安装包、网页源码和发行压缩包均不含这些数据。

## 验证

`GET /health` 提供健康状态。设备用 `POST /v1/pair` 或私有发行包自动配对，之后仅向同一后台的音乐及资料接口发送设备授权令牌。音源或封面 CDN 不接收设备令牌。安装依赖后，在此目录执行 `python -m unittest -v test_server test_qq_provider test_kuwo_provider test_device_library` 可以运行受控回归，测试只使用临时目录和合成资料。

## Unified AI recommendations (0.7.2)

The optional AI Hub connection uses `SIDEA_AI_HUB_URL` and a server-only
`SIDEA_AI_HUB_KEY` issued for the Side A application. HTTPS is required except
for a loopback URL on the same host. Neither value is supplied by a phone, and
the Hub credential must never be placed in an APK, IPA, Git history or browser.

`POST /v1/ai/recommend` accepts a bounded preference summary and up to 60 real
catalog candidates; `GET /v1/ai/tasks/<id>` polls the result. Both use the existing
device bearer token. The bridge derives the subject from the active, nonrevoked
library recovery profile, so reinstalling preserves identity without allowing
one device to read another device's task. Clients cannot specify a subject.

The 0.7.2 clients summarize favorites and the last 30 days of intentional plays,
repeats, completions and quick skips. Pauses, buffering and playback failures are
not negative signals. No audio, playback URL, provider credential, event timestamp
or full listening history is sent. Track IDs are SHA-256 hashes with a mapping
kept only on the device. Models rank known candidates; unknown or duplicate IDs
are ignored, and all playback continues through the existing native player.

Recommendations first display immediately from local rules. AI runs separately,
returns at most 24 selections, and keeps validated ranking IDs for six hours with a
minimum ten-minute model retry interval. Active clients probe configuration at most once per minute without invoking a model, so changing the central assignment invalidates old rankings automatically. Ordinary listening changes keep the last analysis while the next one is prepared; hidden songs, muted styles and recent intentional skips remain excluded. Background clients stop polling. UTF-8 request size is bounded by trimming excess candidates before dispatch. Disabling preference tracking disables AI
recommendations as well. An unconfigured model, unavailable Hub, exhausted
budget or network outage silently retains local recommendations; no fake AI
success is returned and music playback is unaffected. App model assignments and
credentials are maintained in the Hub, not in the player settings.

Synthetic regression checks: `python -m unittest test_ai_bridge` (from this
folder). Supply model details in the Hub admin and perform a real test before
claiming the deployment has live model connectivity.

Slow or queued AI jobs are saved by task ID with their submitted summary and
configuration revision. Foreground clients poll the existing task independently
of the ten-minute generation cooldown; app restarts and background/resume do not
submit another model request. A configuration change invalidates old pending work;
unfinished jobs older than six hours are cancelled before the client forgets them.
`POST /v1/ai/tasks/<id>/cancel` uses the same server-derived subject isolation.
