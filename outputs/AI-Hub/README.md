# AI Hub

统一 AI 配置后台与应用任务接口。软件使用固定能力名称，管理员在后台分配实际模型。音乐推荐在腾讯云独立执行；家庭 OECT 离线不影响普通模型任务。

## 运行

Python 3.12+、PostgreSQL 16+，以及独立的 LiteLLM Proxy。Hub 与 Proxy 使用不同的 PostgreSQL 数据库。Proxy 只监听回环地址，启用数据库模型管理 (`STORE_MODEL_IN_DB=true`)，固定并核验官方发行版本，关闭自动模型重试。Hub 通过 `/model/new` 创建不可变版本的内部别名，通过 `/v1/responses` 或 `/v1/chat/completions` 发起真实请求。

兼容服务商选择 Chat 时，Hub 使用 LiteLLM 的 `custom_openai/<模型名>` 适配器，保持上游 Chat 路径与原模型 ID；Responses 使用 `openai/<模型名>` 原生适配器。[LiteLLM 官方文档](https://docs.litellm.ai/docs/response_api)介绍了兼容接口的 Responses/Chat 桥接。实测 1.108.0 的 Chat 入口会把某些 `openai/` GPT 模型名改走 Responses，即使配置 `use_chat_completions_api=true`；本机协议夹具已验证 `custom_openai/` 实际发出 `/v1/chat/completions`。修改传输定义后应提升模型 revision，避免复用已注册的旧内部别名。

```sh
python -m venv .venv
.venv/bin/pip install -r requirements.txt
# 使用权限 0600 的环境文件配置 .env.example 中的变量；不提交真实文件。
.venv/bin/python manage.py migrate
.venv/bin/gunicorn --bind 127.0.0.1:8780 --workers 2 --timeout 150 app:app
# 另一个独立的 systemd 服务：
.venv/bin/python worker.py
```

HTTPS 反向代理到 127.0.0.1:8780，只允许该代理连接 Hub。代理正确覆盖 `X-Forwarded-For`、`X-Forwarded-Proto`。管理端设置 `AI_HUB_PUBLIC_ORIGIN` 为真实 HTTPS 域名；Cookie 默认 Secure、HttpOnly、SameSite=Strict。管理登录密码仅保存 Werkzeug 密码哈希。服务启动需要实际私密配置，不带默认管理员密码。

Hub 与 LiteLLM 中的加密密钥必须分别保存在独立私密备份中；不能随意重生成，否则已保存的 API Key 无法解密。模型密钥永远不下发手机或家庭节点。应用凭据仅创建/轮换时显示一次，数据库只保存 SHA-256 摘要。应用凭据应仅在各软件的服务端使用，不嵌入安装包。

## 首次配置

1. 登录后台，添加兼容 OpenAI 的公网 HTTPS API 地址及 API Key。手动填写服务商的模型 ID，选择 Responses 或 Chat 协议；不能仅凭模型名假设接口兼容。
2. 选择计费方式。按量计费时填写服务商的美元输入/输出单价，单位为每百万 tokens；缺失价格时拒绝应用调用。已有订阅或固定费用时选择“只统计用量”，不占用逐次费用预算，仍记录实际 tokens；这不表示订阅本身免费。明确免费的按量服务才可填 0。
3. 点击连接测试时，后台发送一条最多 128 输出 tokens 的真实 JSON 请求，可能产生费用。失败只报告脱敏原因，不回显上游响应中的密钥。
4. 添加软件、分配模型与每月额度，将一次性应用接入密钥配置在软件服务端。模型变更对新任务生效；排队任务遇到模型版本改变会失败且不计费，让软件重新提交。

没有配置 Key/模型时返回 `model_unconfigured`。本项目不生成假的 AI 结果，正常播放器应继续使用已有推荐作为回退。

## 应用接口

所有接口返回 `{ok:true,...}` 或 `{ok:false,error:{code,message}}`。应用通过 `Authorization: Bearer <应用密钥>` 鉴权。服务器从密钥确定 `app_id`，请求中不能携带另一个软件的 ID。`subject` 由软件服务端根据已经鉴权的设备/账号生成；不得直接采用手机传来的任意设备标识。

```json
POST /v1/tasks
{
  "subject": "server-derived-profile-id",
  "capability": "music.recommend.v1",
  "idempotency_key": "optional-stable-request-id",
  "input": {
    "profile": {
      "listening": [{"title":"山间清晨","artist":"测试歌手","completions":8,"quick_skips":0}]
    },
    "candidates": [{"id":"opaque-track-id","title":"山间清晨","artist":"测试歌手"}],
    "limit": 1
  }
}
```

返回 `202 {ok:true,task:{id,status,...}}`；同一设备的相同内容缓存/排队合并返回 200。同一应用中不同 `subject` 不共享缓存或结果。全局不同应用严格隔离。

- `GET /v1/tasks/<id>?subject=<subject>` 读取状态。
- `GET /v1/config` 零模型调用的配置探测，返回 `{config:{revision,enabled,min_interval_seconds}}`。revision 是不透明指纹，不暴露模型名和密钥；客户端配置变更后清除旧 AI 排序缓存。模型切换不会被旧模型的最小重算间隔拦住。
- `POST /v1/tasks/<id>/cancel {"subject":"..."}` 取消。尚未发出的请求释放预算；已发出的请求不重复调用，费用按已知用量结算。
- 状态：`queued` → `leased` → `running` → `succeeded` / `failed` / `cancelled`。
- 成功音乐结果：`{profile_summary,ranked:[{id,reason}]}`。只允许输入的真实候选 ID，不接受编造歌曲、重复项、额外 URL 或指令。
- 候选 1–60 首，ID/标题/歌手各最多 200 字符；推荐上限 30 首。传入稳定不透明 ID，不能传流媒体 URL 或认证地址。
- 行为统计最多 6,000 个 JSON 字符，不应上传原始音频、Cookies、密码或凭据。
- 音乐候选可携带布尔值 `familiar`（听过或收藏）、`recent`（最近播放）、`shown`（近期展示），旧客户端省略字段仍可用。排序提示优先探索未听过的歌曲，同时保持歌手多样性；输出仍仅允许真实候选 ID。
- 推荐缓存 6 小时，新应用默认每设备最短重算间隔 5 分钟，管理员可在 60 秒–24 小时之间调整。

## 后台接口

`GET /admin/api/session` 获取登录状态与 `csrf_token`。所有管理写操作（包括登录）必须携带 `X-CSRF-Token`；检查 Origin。`POST /admin/login {password}`，成功后使用新的 CSRF；`POST /admin/logout`。

- `GET /admin/api/state`：providers、models、apps、workers、最近 100 条脱敏 tasks、model_tests、usage 汇总。
- `POST /admin/api/providers`，`PATCH /admin/api/providers/<id>`：`{name,base_url,api_key?,enabled?}`。空 Key 保持原值；`clear_key:true` 明确清除。响应仅 `has_key`，不回显。
- `GET /admin/api/providers/<id>/models`：只读获取上游模型名；不支持列表的接口可手动输入。
- `POST /admin/api/models`，`PATCH /admin/api/models/<id>`：`{name,provider_id,upstream_model,api_mode,billing_mode,input_price_per_million,output_price_per_million,max_input_tokens,max_output_tokens,enabled}`。`billing_mode` 为 `metered` 或 `subscription`，默认按量计费。
- `POST /admin/api/models/<id>/test {confirm_cost:true}`：返回 `{test:{success,error,input_tokens,output_tokens,estimated_usd,cost_known}}`。
- `POST /admin/api/apps`，`PATCH /admin/api/apps/<id>`：`{name,model_id,monthly_budget_usd,min_interval_seconds,capabilities,enabled}`。初次创建返回一次性 `api_key`。
- `POST /admin/api/apps/<id>/rotate-key`：立即撤销旧应用密钥并返回新值。
- `POST /admin/api/workers`，`PATCH /admin/api/workers/<id>`：`{name,app_ids:[...],enabled}`。初次创建返回一次性 `api_key`，只授权列出的应用。

## OECT Hermes 节点

节点不需要家庭入站 80/443，主动访问云端 HTTPS。必须以独立系统用户、独立每任务工作目录和 `HERMES_HOME` 启动 Hermes，禁止继承个人 Hermes 的配置、记忆或工具。当前只开放 `hermes.analyze.v1` 单轮只读文本分析，`input:{text}`，结果严格为 `{summary}`。应用需由管理员显式启用此能力。普通音乐推荐永远不会交给家庭节点。

节点使用自己的 Bearer 凭据：

- `POST /v1/worker/status {ready,model_configured,agent_version,capabilities:["hermes.analyze.v1"]}`：只心跳，不领取任务；无模型/运行条件时上报 `ready:false`。
- `POST /v1/worker/claim {}`：返回 task 或 null。只领取授权应用的 Hermes 任务；`ready` 与 `model_configured` 均需为 true。
- 租约包含 `id,app_id,subject,capability,input,lease_token,max_output_tokens,model_base_url,model_api_key,model`。`model_api_key` 就是本次租约短期令牌，不是服务商 Key。
- 执行前 `POST /v1/worker/start {task_id,lease_token}`；每 20 秒 `POST /v1/worker/heartbeat` 同样字段；超过租约不能开始。
- Hermes 使用返回的 `model_base_url` 与 `model_api_key`，`enabled_toolsets=[]`、`max_iterations=1`、关闭记忆/背景复盘/上下文文件，非流式 Chat 调用。Hub 固定服务端任务模板、输入、模型和输出上限，忽略客户端传来的 model/messages；不允许 tools/functions。
- 每任务只允许一次真实模型调用；重复调用返回已保存响应，不重复计费；超时/执行中返回错误，不重新发送。
- `POST /v1/worker/complete {task_id,lease_token,result:{summary}}`，失败时 `error:true`。只有已经完成真实中央模型调用且结果一致才算成功；计费信任 Hub 观察到的用量，不信任节点填报数值。

节点可在无模型配置时正常联网心跳，后台应显示“在线，待配置”，不宣称已经验证真实模型调用。

## 预算、重试与数据边界

任务提交在应用行锁内检查本月已结算+预留费用，再原子预留，防止多个设备同时透支。预留使用 UTF-8 字节数加消息封装余量作为保守文本输入上界，加配置的最大输出。已知 token 使用量按配置价格结算；未知用量/超时保留全部预留费用并标记估算，绝不记为免费。供应商实际账单、附加费用以及不遵守 token 上限的接口不属于可保证边界；该情况应停用服务商并人工核对。

订阅/固定费用模式只记录用量，内部逐次费用记为 0 且状态明确标记 `usage_only`。软件原有按量预算继续保存以供以后切换，但不限制订阅调用。每项任务保存创建时的计费模式，后续配置变化不改写既有任务的计费记录；切回按量模式需要明确填写真实单价。

未开始的租约可回收最多 3 次。已经发送的模型任务失联后标记失败并保守计费，不自动重新发起可能计费的请求。取消不会产生第二次调用。模型 API 自动重试必须在 LiteLLM 中关闭。

任务的输入、推荐内容与 relay 响应在完成 30 天后清除；保留有限计费/状态信息。管理列表不显示设备原始行为和提示词。相同租约内的 Hermes 返回可复用，租约到期、取消或完成后短期凭据立即失效。

API 地址只允许公网 HTTPS 443，无 userinfo、query、fragment。保存和每次模型调用前拒绝内网/回环/链路本地 DNS 结果，禁止自动跳转。部署还应在 LiteLLM 出站网络层拒绝内网与云元数据地址，补足 DNS 重绑定与第三方代理自身重定向行为的风险边界。

## 测试

```sh
python -m pytest tests -q
# 独立 PostgreSQL 测试库，名称必须以 _test 结尾。测试会清空此库的 Hub 表。
TEST_DATABASE_URL=postgresql://.../ai_hub_test python -m pytest tests -q
```

测试包括鉴权/CSRF、加密与密钥轮换、软件与设备隔离、候选约束、没有 Key/价格、恶意地址、并发预算预留、租约回收、取消计费、数据保留、以及 Hermes 单次任务令牌代理。测试模型全部使用受控桩，不发出付费 API 请求。

## 已验证的轻量部署方式

本次使用独立系统用户和 systemd，不需要 Docker。LiteLLM 固定为 1.108.0，Prisma Python 为 0.15.0；先在私有运行环境生成 `litellm/proxy/schema.prisma` 的客户端，再以受限用户运行。系统需保留 Prisma 引擎的缓存目录。示例服务及网关配置位于 `deploy/`。

`deploy/egress.nft` 只约束两个 AI 服务用户，不替换主机原有规则。阻止内网和云元数据目标，保留数据库、DNS、网关自身及 Prisma 的必要回环连接；Prisma 临时端口范围应与主机 `ip_local_port_range` 一致。反向代理仍只连接回环端口。

`deploy/backup.sh` 与对应 timer 每天保存两个数据库和加密配置，保留约 7 天，目录仅 root 可读。此为同机恢复备份；应另外将私密备份复制到可信的离线位置。域名证书使用 DNS 验证并配置自动续期，家庭设备不参与证书申请。
