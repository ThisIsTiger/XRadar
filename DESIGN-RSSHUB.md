# XRadar X 双 Provider 改造设计：RSSHub 优先 + X WebView 显式回退

> 文档状态：评审修订版，可直接交给 AI 按第 13 节实施
>
> 本文是 `DESIGN.md` 的增量设计。未提到的行为以 `DESIGN.md` 为准。

---

## 1. 结论与范围

### 1.1 本期目标

1. 新增 RSSHub Provider，默认优先通过 RSSHub 获取 X 用户时间线，降低 XRadar 本机登录账号被 X 风控的概率。
2. 保留现有 `XSession` + `WebViewTimelineProvider`，仅在用户明确选择时使用。
3. 保证现有规则语义不退化：账号归属、回复、转发、发布时间、三天有效期、最多十条、去重和首次基线都必须正确。
4. 在软件界面中展示实际使用的 Provider、RSSHub 实例、失败原因和是否发生回退。

### 1.2 边界说明

- 本期是 **X 的双 Provider 改造**，不是完整的多平台改造。
- RSSHub 与 X WebView 是同一内容平台的两种获取方式，不能与 Mastodon、Bluesky 等平台概念混用。
- RSSHub 实例仍需在服务端配置 X `auth_token` 或 X Developer API 凭据。XRadar 使用 RSSHub 时不直接接触这些凭据，但实例自身仍可能受到 X 风控。
- 第三方 RSSHub 实例可以看到 XRadar 请求的账号 handle；UI 必须提示这一隐私边界。
- 应用不内置任何 RSSHub 实例推荐（公共实例的 Twitter 路由已普遍停用，实测不可用），实例地址一律由用户自行提供并验证。
- 除 X 规则外还支持**自定义 RSS 源规则**（§13）：用户提供任意 HTTP(S) RSS/Atom 订阅地址即可加入监控。它不依赖 RSSHub 实例、不经过 Router 与策略、不访问 X。

### 1.3 本期不做

- 不接入 X 官方 API。
- 不实现 Mastodon、Bluesky 平台规则（自定义 RSS 源规则的实现见 §13，规则模型仍统一为 MonitorRule）。
- 不自动搜索、爬取或轮换互联网上的公共 RSSHub 实例。
- 不自动把 WebView 当作 RSSHub 的无条件回退。
- 不改写现有 WebView DOM 提取逻辑；只允许通过适配器接入新路由层。

---

## 2. 不可违反的行为约束

1. `rssHubOnly` 模式下不得创建抓取用 `WKWebView`、不得调用 `XSession.validateSession()`、不得向 `x.com` 或 `twitter.com` 发起请求。
2. `xWebOnly` 模式保持当前行为。
3. `rssHubThenXWeb` 只有在用户确认风险、RSSHub 返回允许回退的瞬时错误、且本轮尚未回退时，才可调用 X WebView。
4. 自动化测试不得访问真实 RSSHub 或 X；必须使用 fixture、Mock Provider 或 `URLProtocol` Stub。
5. 不记录 Cookie、RSSHub 服务端凭据、完整 HTML/XML 响应或包含凭据的 URL。
6. 每个账号每轮最多向 Pipeline 返回最近十条 X 内容；按发布时间从新到旧排序。
7. 首次健康抓取只建立基线，不发送历史通知。
8. 初始化后，三天内首次出现且 ID 未见过的内容必须参与规则判断；RSS 缓存延迟不能导致永久漏报。
9. 已见过的 ID 不得再次生成事件或重复写入抓取历史。
10. 不可信的空 Feed 不得推进成功游标。
11. `sourceSetupCompleted == false` 时禁止任何检查，包括手动"立即检查"；直到用户在 UI 完成信源配置或显式确认继续使用 X WebView。**例外（§13）：存在已启用的自定义 RSS 源规则时允许检查**——feed 规则不依赖 RSSHub 实例或 X 登录。

---

## 3. 架构

```text
Settings / AppConfiguration
  └─ XSourceSettings（策略、实例、风险确认）
                   │ 每轮传入配置快照
                   ▼
MonitoringPipeline
  └─ XTimelineRouter
       ├─ RSSHubTimelineProvider
       │    ├─ RSSHubHTTPClient（Cookie-free URLSession）
       │    ├─ RSS/Atom Parser
       │    └─ InstanceHealthTracker
       └─ WebViewTimelineProviderAdapter
            └─ XSession（仅真正使用 xWeb 时验证登录）
                   │
                   ▼
TimelineFetchResult（Tweet + Provider 来源 + Feed 健康信息）
  └─ 去重 → 三天窗口 → 规则 → 事件 → 通知 → 抓取诊断
```

### 3.1 平台与 Provider 分离

本期内容平台恒为 X，只新增 Provider 标识：

```swift
public enum TimelineProviderID: String, Codable, CaseIterable, Sendable {
    case rssHub
    case xWeb
}

public enum XSourcePolicy: String, Codable, CaseIterable, Sendable {
    case rssHubOnly
    case xWebOnly
    case rssHubThenXWeb
}
```

不要给 `Tweet` 增加名为 `source` 且取值为 `.rssHub`/`.xWeb` 的字段。这会混淆“平台”和“传输方式”。Provider 来源放在抓取结果及诊断记录中。

未来真正支持多平台时，再引入：

```swift
struct ContentKey: Hashable, Codable, Sendable {
    let platform: PlatformID
    let accountID: String
    let itemID: String
}
```

本期 X Tweet ID 全局唯一，跨 RSSHub/X WebView 继续使用同一 ID 去重。

### 3.2 Provider 协议

```swift
public struct TimelineFetchResult: Sendable {
    public let tweets: [Tweet]
    public let providerID: TimelineProviderID
    public let instanceHost: String?
    public let fallbackFromProviderID: TimelineProviderID?
    public let rawItemCount: Int
    public let feedState: FeedState
}

public enum FeedState: Sendable, Equatable {
    case healthy
    case notModified
}

public protocol TimelineProvider: Sendable {
    var id: TimelineProviderID { get }
    func fetch(_ request: TimelineRequest) async throws -> TimelineFetchResult
}
```

`rawItemCount` 是解析前有效条目数，不能用“排除已见 ID 后的数量”判断 Feed 是否为空。

### 3.3 Router，而不是简单 Registry

`autoFallback` 是一次带状态的抓取编排，不能由 `provider(for:) -> Provider` 的简单注册表实现。使用 actor：

```swift
public actor XTimelineRouter {
    func fetch(
        _ request: TimelineRequest,
        settings: XSourceSettings
    ) async throws -> TimelineFetchResult
}
```

路由规则：

| 策略 | 行为 |
|---|---|
| `rssHubOnly` | 只调用 RSSHub；任何情况下都不访问 X |
| `xWebOnly` | 调用 X WebView；调用前才验证 XSession |
| `rssHubThenXWeb` | RSSHub 全部实例发生可回退错误后，本轮最多调用一次 X WebView |

`MonitoringPipeline` 不再持有或预先验证 `XSession`。`XSession` 只存在于 WebView Provider Adapter 内部。

---

## 4. 配置与迁移

### 4.1 配置模型

```swift
public struct XSourceSettings: Codable, Equatable, Sendable {
    var policy: XSourcePolicy
    var rssHubInstances: [String]
    var webFallbackRiskAcknowledged: Bool
    var sourceSetupCompleted: Bool
}

public struct AppConfiguration {
    // 原字段保持不变
    var schemaVersion: Int                 // 升至 2
    var xSourceSettings: XSourceSettings
}
```

默认值：

- 新安装：`policy = .rssHubOnly`。
- `rssHubInstances = []`，没有实例时显示"需要配置信源"，不启动抓取。
- 不内置任何 RSSHub 实例（无预设列表）。实例地址由用户自行添加（自建或自行验证可用性的实例），绝不自动启用。
- `webFallbackRiskAcknowledged = false`。
- `.rssHubThenXWeb` 必须在确认风险后才能保存。

### 4.2 v1 → v2 迁移

必须为 `AppConfiguration` 实现自定义 `init(from:)`，所有新增字段使用 `decodeIfPresent`。禁止依靠合成 `Codable`，否则旧配置解码失败后会退回 `.default` 并丢失规则。

迁移规则：

1. 原有规则、通知设置、轮询间隔和历史设置原样保留。
2. v1 用户设置 `policy = .xWebOnly`，但 `sourceSetupCompleted = false`。
3. Scheduler 在 `sourceSetupCompleted == false` 时不自动检查，UI 要求用户确认继续使用 X WebView 或配置 RSSHub。
4. 用户作出选择并保存后才恢复调度（自动与手动"立即检查"均恢复）。
5. 迁移完成后写回 `schemaVersion = 2`。

### 4.3 一分钟枚举兼容

保留 `PollingInterval.oneMinute` 用于解码旧配置，但从新 UI 选项中隐藏。不得直接删除枚举 case。

### 4.4 实例配置校验

保存前必须：

- 去除首尾空格和末尾 `/`。
- URL 必须包含 host；禁止用户名、密码和 fragment。
- 默认只允许 HTTPS。本机自建实例可显式允许 `http://localhost`、`http://127.0.0.1` 和 `http://[::1]`。
- handle 去除开头 `@`，只允许 X 用户名字符集 `[A-Za-z0-9_]{1,15}`。
- 无效实例只阻止该配置保存，不得重置整个配置文件。

---

## 5. RSSHub 请求设计

### 5.1 路由构造

RSSHub Twitter 用户路由的 `routeParams` 是路径段。必须使用 `URLComponents`/安全路径编码构造，禁止字符串直接拼接。

逻辑模板：

```text
{baseURL}/twitter/user/{handle}/includeReplies={0|1}&includeRts={0|1}&count=10&showEmojiForRetweetAndReply=1&showSymbolForRetweetAndReply=0&showQuotedInTitle=0
```

参数来自 `TimelineRequest`：

| TimelineRequest | RSSHub 参数 |
|---|---|
| `includeReplies` | `includeReplies=1/0` |
| `includeReposts` | `includeRts=1/0` |
| `maximumCount` | `count=min(maximumCount, 10)` |

设置固定的机器可识别前缀：回复 `↩️`，转发 `🔁`。Parser 必须先识别并移除前缀，再把剩余正文交给规则引擎。

### 5.2 HTTP 客户端

- 使用独立的 ephemeral `URLSessionConfiguration`，关闭共享 Cookie 和凭据存储。
- 请求头：`Accept: application/atom+xml, application/rss+xml, application/xml, text/xml`。
- 总超时 10 秒。
- 最大响应体 5 MiB，超出即 `.responseTooLarge`。
- 支持 `ETag`/`Last-Modified`；304 返回 `.notModified`，不得当作空 Feed 失败。
- 只接受 2xx 或 304。解析前检查状态码。
- 重定向只允许保持在原配置 host，且不得跳转到 `x.com`、`twitter.com` 或其他 host；否则取消并报告 `.redirectRejected`。
- 不下载 Feed 内图片、视频、头像或正文链接。

### 5.3 RSS/Atom 解析

同时支持：

- RSS 2.0：`item/title`、`description`、`link`、`guid`、`pubDate`、`author`。
- Atom：`entry/title`、`content`/`summary`、`link[href]`、`id`、`published`/`updated`、`author/name`。

安全要求：

- 禁止解析外部实体或加载外部 DTD。
- 限制单条正文长度，例如 100 KiB。
- HTML 只做实体解码、去标签和空白归一化，不执行脚本、不加载资源。

### 5.4 X 字段映射

| Tweet 字段 | 映射规则 |
|---|---|
| `id` | 从 canonical link 的 `/status/{numericID}` 提取；无合法数字 ID 则丢弃 |
| `url` | 使用合法的 X status link；统一 host 为 `https://x.com` |
| `authorHandle` | 始终使用规范化后的请求 handle；不得使用 `author.name` |
| `text` | 优先使用 `title`，移除 RSSHub 固定类型前缀；空文本使用“发布了一条媒体推文” |
| `kind` | `↩️` → `.reply`；`🔁` → `.repost`；否则 `.original` |
| `publishedAt` | 优先使用 X Snowflake ID 推导的时间；RSS 日期用于交叉验证和非 Snowflake fallback |
| `isPinned` | RSSHub 无可靠字段，固定 `false` |

X Snowflake 时间公式：

```text
timestampMs = (tweetID >> 22) + 1288834974657
```

实现时用 `UInt64` 解析和右移 Tweet ID。推导结果必须处于 X 上线时间之后且不晚于当前时间五分钟；不在合理范围时回退 RSS 日期。若 RSS 日期和有效 Snowflake 时间相差超过允许误差，使用 Snowflake 时间并在 Debug 诊断中记录“不一致”，不得记录完整 Feed。

这样可避免 RSSHub 对转发使用原推发布时间，导致“刚发生的转发”被三天窗口错误丢弃。

### 5.5 排序、去重与数量

Provider 返回前执行：

1. 按 Tweet ID 去重。
2. 丢弃缺少有效 ID、URL 或发布时间的条目。
3. 按 `publishedAt` 倒序；时间相同则按数值 Tweet ID 倒序。
4. 截取最多 `min(request.maximumCount, 10)` 条原始候选。
5. 返回给 Pipeline 前丢弃早于当前时间三天的条目，但保留未过滤的 `rawItemCount`。

`excludedTweetIDs` 只用于减少后续转换工作，不能改变 `rawItemCount`，也不能把“Feed 有内容但均已见过”误判成空 Feed。

---

## 6. 空 Feed、缓存延迟与游标语义

RSSHub Twitter 路由可能在上游异常时返回 HTTP 200 且无 item，因此“HTTP 成功 + 0 item”不是可靠成功。

### 6.1 Feed 状态判定

| 场景 | 处理 |
|---|---|
| HTTP 304 | 健康的 `.notModified`；无新内容 |
| 原始 Feed 有 item，但全被三天窗口/已见 ID 过滤 | 健康；无新内容 |
| 已初始化账号收到 2xx 且 `rawItemCount == 0` | `.suspiciousEmpty`；尝试下一实例 |
| 未初始化账号收到 2xx 且 `rawItemCount == 0` | `.emptyUnverified`；尝试下一实例，不建立基线 |
| 全部实例均为空或不可信 | 本轮 degraded，不更新成功时间 |

### 6.2 Cursor 新语义

- `lastCheckedAt`：完成一次尝试后更新，可用于 UI。
- `lastSuccessfulFetchAt`：仅当 Provider 返回 `.healthy` 或 `.notModified` 时更新，只用于运行状态与诊断。
- `lastSuccessfulFetchAt` **不得再作为通知过滤条件**。
- 首次健康抓取且 `rawItemCount > 0`：保存返回的三天内 ID，设置 `initialized = true`，全部记为 `.baseline`，不通知。即使 Feed 只有三天前的旧条目，也可以建立空基线。
- 初始化后：`ID 未见过 && publishedAt >= now - 3 days` 的内容参与规则判断，即使发布时间早于上次成功抓取时间。
- 如果某个 Provider 仍返回了超过三天的 ID，记为 `.historical` 并加入 seen IDs，禁止通知；RSSHub Provider 正常情况下会在边界处提前过滤。
- seen IDs 继续保留最多 300 个。

这组规则同时满足“不过度补录”和“RSS 延迟出现时不漏报”。

---

## 7. 多实例与错误处理

### 7.1 错误类型

新增与页面 DOM 无关的错误，禁止把 RSS 错误映射成 `.pageStructureChanged`：

```swift
public enum SourceError: Error, Sendable {
    case configurationRequired
    case invalidInstanceURL
    case accountUnavailable(statusCode: Int)
    case rateLimited(provider: TimelineProviderID, retryAfter: Date?)
    case networkUnavailable(provider: TimelineProviderID)
    case requestTimeout(provider: TimelineProviderID)
    case invalidFeed
    case suspiciousEmpty
    case emptyUnverified
    case responseTooLarge
    case redirectRejected
    case authenticationRequired(provider: TimelineProviderID)
    case userActionRequired(String)
}
```

### 7.2 RSSHub 实例 fallback

`InstanceHealthTracker` 为 actor，并在本次 App 生命周期内保存每个 baseURL 的状态：

- 优先使用上一次成功实例，再按配置顺序尝试。
- 429：遵守 `Retry-After`，缺失时冷却 15 分钟。
- 5xx、网络错误、超时：冷却 2 分钟。
- 无效 Feed、可疑空 Feed：冷却 5 分钟。
- 冷却中的实例对后续账号直接跳过，避免每个账号重复轰炸同一个故障实例。
- 任一实例成功后，本轮不再请求其他实例。
- 某实例失败但后续实例成功时，本轮总体成功；失败信息只进入诊断，不触发全局 backoff。

### 7.3 是否允许回退到 X WebView

允许回退：

- 全部可用 RSSHub 实例均为超时、网络错误、5xx、429、无效 Feed 或可疑空 Feed。

禁止回退：

- 配置未完成或实例 URL 无效。
- 明确的账号不存在/不可用（HTTP 404/410）。
- 用户未确认 WebView 风险。
- 本轮已经使用过一次 WebView。
- XSession 没有登录；此时返回 `.authenticationRequired(.xWeb)`，不自动弹登录窗口。

---

## 8. Pipeline、调度与动态配置

### 8.1 每轮传入配置快照

当前 Scheduler 每轮已经加载最新 `AppConfiguration`。扩展调用：

```swift
pipeline.runCheck(
    reason: reason,
    rules: configuration.rules,
    accountCursors: runtimeState.accounts,
    sourceSettings: configuration.xSourceSettings
)
```

不要在 `AppModel.init()` 时按默认配置构造固定 Provider，也不要在设置变化后重建整个 Pipeline。Router 每轮使用配置快照，保存设置后下一轮立即生效。

### 8.2 调度抖动

- 仅计划任务在基础间隔上增加 `-20%...+20%` 随机抖动。
- 手动检查、启动检查、唤醒检查不加抖动。
- backoff 截止时间不再二次加抖动。
- 一分钟选项只为旧配置解码保留；用户重新选择后最短为五分钟。
- 使用可注入随机数源测试边界，避免不可重复测试。

### 8.3 Backoff 映射

- Router 已通过其他 RSSHub 实例恢复：Scheduler 不 backoff。
- RSSHub 全部 429：使用最早可重试时间。
- RSSHub 全部瞬时失败：短退避，默认 2 分钟。
- X WebView 的挑战、限流和登录状态继续沿用现有策略。
- 配置缺失：状态为“需要配置信源”，不循环重试；同时禁用手动“立即检查”（见 §2 约束 11）。

---

## 9. 规则语义

1. Pipeline 仍按账号合并规则，并以“任一规则需要回复/转发”决定上游请求范围。
2. Provider 必须可靠设置 `Tweet.kind`，随后每条规则继续独立应用 `includeReplies`/`includeReposts`。
3. `authorHandle` 必须是规范化后的受监控账号，否则 `KeywordMatcher` 会拒绝该 Tweet。
4. 引用推文正文不得混入主推文正文参与关键词匹配；只匹配发布者自己的正文。
5. 空媒体推文使用统一占位文案，但不得凭空生成正文内容。

---

## 10. UI 与诊断

### 10.1 设置 → 信源

- 策略 Picker：
  - `RSSHub（推荐）`
  - `应用内 X 登录抓取`
  - `RSSHub 失败后回退 X（有风控风险）`
- RSSHub 实例列表：添加、删除、排序、启用/停用。
- 不内置实例预设；用户自行添加实例并可用"测试信源"验证。第三方实例旁统一提示“实例运营者可以看到你查询的账号”。
- “测试信源”：选择一个已有规则账号，仅执行一次 RSSHub 测试。
- 测试结果显示：最终 URL host、HTTP 状态、原始条目数、有效条目数、最新发布时间、耗时和错误。
- 测试不得写入 Cursor、抓取历史、事件，也不得发送通知或回退 WebView。
- 第三方实例旁提示：“实例运营者可以看到你查询的账号”。
- 选择自动回退时显示封号风险确认；未确认时禁止保存。

### 10.2 登录入口

- `rssHubOnly`：登录按钮弱化并标注“当前信源不需要登录”。
- `xWebOnly`/`rssHubThenXWeb`：正常显示登录状态。
- 只有存在可用 RSSHub 实例且源配置完成的前提下，Scheduler 才允许自动/手动检查。

### 10.3 抓取记录

`FetchRecord` 新增可选字段，并把 wrapper schema 升至 4：

```swift
let providerID: TimelineProviderID?
let instanceHost: String?
let fallbackFromProviderID: TimelineProviderID?
```

旧记录缺失字段时正常解码为 `nil`。界面每条记录显示：

- Provider：RSSHub 或 X WebView。
- RSSHub 实例 host，不显示完整 URL 查询内容。
- 是否由 RSSHub 回退至 X WebView。
- 发推时间和抓取时间。
- Feed 失败时显示具体错误类型，不使用“X 页面结构变化”描述 RSS 错误。

---

## 11. 持久化与安全

- `config.json` schemaVersion：2；必须兼容 v1。
- `fetch-history.json` schemaVersion：4；必须兼容 v2/v3。
- `state.json` 与 `events.json` 本期结构不变。
- RSSHub 实例 URL 不得包含用户名、密码或 token。
- 未来如支持带认证的 RSSHub 实例，token 必须存 Keychain，配置文件只保存凭据引用 ID。
- 日志只允许记录 Provider、实例 host、状态码、耗时、条目数量和错误类型。
- 禁止记录 Cookie、Authorization、完整 Feed、完整 HTML 或 URL 中的敏感查询参数。

---

## 12. 必须新增的测试

### 12.1 配置迁移

- v1 配置升级后所有规则和通知设置保持一致。
- v1 的一分钟间隔可以解码，但 UI 不再提供该选项。
- 新字段缺失时不会导致 Repository 返回 `.default`。
- 无效实例配置不会清空其他配置。

### 12.2 Parser fixture

- RSS 2.0 与 Atom 各一套。
- 原创、回复、转发、引用、媒体空正文。
- `author.name` 是显示名，但输出 handle 必须仍为请求 handle。
- 重复 ID、无效 link、无日期、乱序条目。
- HTML 实体、标签、CDATA、多语言正文。
- 转发 RSS 日期很旧但 Snowflake ID 很新时，使用 Snowflake 时间。
- 超大响应和外部实体不能被加载。

### 12.3 路由与 HTTP

- `includeReplies`、`includeRts`、`count=10` 映射正确。
- handle 与 baseURL 正确编码。
- 302 到其他 host 或 X 必须拒绝。
- 304 映射为 `.notModified`。
- 429 读取 `Retry-After`。
- 实例 A 500 → 实例 B 成功。
- 实例 A 429 后，同轮其他账号不再请求 A。
- 2xx 空 Feed → 尝试下一个实例。

### 12.4 Router 与零 X 流量

- `rssHubOnly` 下 XSession 和 WebView Provider 调用次数均为 0。
- `xWebOnly` 只调用 WebView。
- `rssHubThenXWeb` 在 RSSHub 成功时不调用 WebView。
- 允许回退的错误只触发一次 WebView。
- 404、配置错误、未确认风险时不触发 WebView。
- RSSHub 失败且 X 未登录时不自动打开登录窗口。

### 12.5 Pipeline 与 Cursor

- 首次健康且 `rawItemCount > 0` 的 Feed 只建立基线。
- 首次空 Feed 不初始化 Cursor。
- 空 Feed 不推进 `lastSuccessfulFetchAt`。
- RSS 缓存延迟出现的三天内未见 ID 仍会触发规则。
- 超过三天的未见 ID 只记历史、不通知。
- 同一 Tweet 在 RSSHub 与 X WebView 间切换不重复通知。
- 十条限制、时间倒序和 300 ID 上限保持正确。

### 12.6 回归

- 现有 WebView Provider 测试不修改预期行为。
- 现有 XCTest 全部通过。
- `XRadarVerifier` 全部通过。
- `./scripts/verify.sh` 退出码为 0。

---

## 13. 自定义 RSS 源（非 X 信源）

> 适用场景：用户没有可用 RSSHub 实例（公共实例的 X 路由已普遍失效），但需要监控其他站点/平台的 RSS/Atom 订阅。

### 13.1 规则模型

- `MonitorRule` 增加可选字段 `feedURL: String?`。`nil` = X 账号规则（行为完全不变）；非 nil = 自定义 RSS 源规则。
- feed 规则的 `accountHandle` 仅为显示名（通知、历史、列表展示），不参与匹配。
- 同一 `feedURL` 的多条规则共享一次抓取与一个 cursor（键为 feed URL 原文，保存前 UI 做空白裁剪）。

### 13.2 通用解析与映射

- `XRSSParser.parseGeneric(data:defaultAuthor:maximumCount:excludedTweetIDs:now:)` 复用 §5.3 的 XML 解析与 §5.4/§5.5 的去重、排序、排除、十条截取、三天窗口。
- 条目映射（与 X 映射的差异）：
  - id：优先 X 推文 ID（链接为 `x.com/status/N` 时与 X 路径去重互通），其次 guid，最后 link。
  - url：必须是可解析的绝对 http(s) URL（link 或 guid）；没有可跳转地址的条目跳过。
  - 正文：标题优先、摘要兜底，HTML 清洗后为空则跳过。
  - 时间：RSS 日期 → Snowflake 推导 → **无日期按 now 处理**（视为新条目参与窗口，避免漏报）。
  - 作者：条目 author 名，缺失用源域名；kind 恒为 `.original`。
- 上限与安全限制与 X 路径一致：5 MiB、每条 100 KiB、10 条截取、三天窗口。

### 13.3 抓取与安全

- `RSSDirectFeedProvider`（§5.2 客户端复用）：无 Cookie、10s 超时、单 host 重定向白名单、禁 x.com/twitter.com 域名、ETag/304 支持。
- 直接抓取用户提供的 URL，**不经过 Router 与 XSourcePolicy**；`xWebOnly`/`rssHubOnly` 策略对它无影响。
- 空 Feed 语义与 §6.1 对齐：未初始化 → `emptyUnverified`；已初始化 → `suspiciousEmpty`；`notModified` 视为健康。

### 13.4 Pipeline 与调度

- `MonitoringPipeline` 按 `feedURL` 分组抓取，复用与 X 账号完全相同的"窗口 → 去重 → 规则 → 事件 → 通知 → 历史"处理与错误分类。
- `PollScheduler` 的配置门槛（约束 11）增加例外：存在已启用的 feed 规则即允许检查。
- 关键词匹配对 feed 规则跳过账号归属校验（§9），其余规则语义（排除词、匹配模式、大小写、触发模式、通知渠道）不变。

### 13.5 诊断与 UI

- 抓取历史 `providerID == .rssFeed`，`instanceHost` 记录 feed 域名；规则列表展示"RSS 源 · 域名"徽标。
- 规则编辑器提供"X 账号 / 自定义 RSS 源"源类型切换；feed 规则隐藏"包含回复/转发"选项。
- 信源状态摘要：存在已启用 feed 规则时优先展示"自定义 RSS 源已配置（N 个）"。

## 14. AI 可执行任务清单

执行规则：按顺序完成；每个任务结束先运行该任务的最小测试，再开始下一项。不得为通过测试而删除既有断言。发现设计与代码冲突时先更新本文，再实施代码。

### TASK-01：配置模型与无损迁移

**依赖：** 无

**修改范围：**

- `Sources/XRadarCore/Models/AppConfiguration.swift`
- `Sources/XRadarCore/Persistence/ConfigurationRepository.swift`
- 配置持久化测试

**实施：**

- 新增 `TimelineProviderID`、`XSourcePolicy`、`XSourceSettings`。
- AppConfiguration schema 升至 2，实现自定义 Codable。
- 按第 4.2 节迁移 v1，完整保留规则。
- 保留 `.oneMinute` 解码能力，提供单独的 UI 可选间隔集合。
- 校验并规范化实例 URL。

**完成标准：** 第 12.1 节测试全部通过；加载旧配置不会丢失任何规则。

### TASK-02：抓取协议与错误模型

**依赖：** TASK-01

**修改范围：**

- `Sources/XRadarCore/Timeline/TimelineProvider.swift`
- 新增 Router/Provider 公共模型文件
- 所有 Mock Provider 与 Verifier

**实施：**

- 将 Provider 返回值改为 `TimelineFetchResult`。
- 新增 `FeedState` 和 `SourceError`。
- 为现有 WebView Provider 增加 Adapter，返回 `.xWeb` 来源；不修改 DOM 提取行为。
- 让项目先恢复编译，再进入 RSSHub 实现。

**完成标准：** Debug/Release 均编译；现有 WebView 单测继续通过。

### TASK-03：RSS/Atom Parser 与 X 映射

**依赖：** TASK-02

**修改范围：**

- 新增 `Sources/XRadarCore/Timeline/RSS/` 目录
- 新增脱敏 HTML/XML fixtures
- Parser 单元测试与 Verifier 覆盖

**实施：**

- 实现 RSS 2.0/Atom 解析和安全限制。
- 实现固定类型前缀、status ID、handle、正文和 Snowflake 时间映射。
- 实现三天过滤、排序、批内去重和十条上限。

**完成标准：** 第 12.2 节全部通过；fixture 不含真实 Cookie 或个人数据。

### TASK-04：RSSHub HTTP、请求构造与实例健康

**依赖：** TASK-03

**修改范围：**

- `RSSHubRequestBuilder`
- `RSSHubHTTPClient`
- `RSSHubTimelineProvider`
- `InstanceHealthTracker`
- URLProtocol Stub 测试

**实施：**

- 按第 5 节实现无 Cookie HTTP 客户端、重定向限制、响应大小限制和条件请求。
- 按第 7.2 节实现实例 fallback 与 cooldown。
- 空 Feed 必须依据 `rawItemCount` 处理。

**完成标准：** 第 12.3 节全部通过；同一故障实例不会被每个账号重复请求。

### TASK-05：Router 与 X 零流量保证

**依赖：** TASK-04

**修改范围：**

- 新增 `XTimelineRouter`
- `MonitoringPipeline`
- `AppModel`
- Router Mock 测试

**实施：**

- 从 Pipeline 移除无条件 XSession 验证。
- XSession 验证下沉到 WebView Adapter。
- 实现三种策略和严格的回退条件。
- 确保测试信源永不回退 WebView。

**完成标准：** 第 12.4 节全部通过；`rssHubOnly` 的 x.com 请求计数严格为 0。

### TASK-06：Cursor、去重与诊断修复

**依赖：** TASK-05

**修改范围：**

- `MonitoringPipeline.swift`
- `FetchRecord.swift`
- `FetchHistoryRepository.swift`
- Pipeline/持久化测试

**实施：**

- 按第 6.2 节移除 `publishedAt > lastSuccessfulFetchAt` 通知门槛。
- 正确处理 baseline、延迟内容、历史内容、notModified 和不可信空 Feed。
- FetchRecord schema 升至 4，记录 Provider/instance/fallback 来源。
- 已见 Tweet 不得重复写入记录或事件。

**完成标准：** 第 12.5 节全部通过；模拟 RSS 延迟恢复时不漏通知、不重复通知。

### TASK-07：Scheduler 动态配置、抖动与 backoff

**依赖：** TASK-06

**修改范围：**

- `PollScheduler.swift`
- Scheduler 测试和 Mock Pipeline

**实施：**

- 每轮把最新 `XSourceSettings` 传给 Pipeline。
- 实现只针对计划任务的 ±20% 抖动和可注入随机数源。
- 实现 source-aware backoff 与 configuration-required 状态。
- `sourceSetupCompleted == false` 时禁止任何检查（自动与手动"立即检查"均禁用）。

**完成标准：** 手动/启动/唤醒检查不被抖动；现有防重入测试继续通过。

### TASK-08：设置、状态与抓取诊断 UI

**依赖：** TASK-07

**修改范围：**

- `XRadar/UI/Settings/`
- `XRadar/UI/FetchHistoryView.swift`
- `XRadar/App/AppModel.swift`

**实施：**

- 实现信源策略、实例管理（用户自行添加/删除/排序，无内置预设）、风险确认和无副作用测试按钮。
- 展示 Provider、实例 host、回退来源、发推时间与抓取时间。
- 根据策略调整 X 登录入口。
- 配置未完成、RSSHub 不可用和 X 登录失效必须显示不同状态。

**完成标准：** 用户无需命令行即可判断当前使用哪个信源、抓到了什么、为何失败、是否发生回退。

### TASK-09：全量回归与文档收尾

**依赖：** TASK-01 至 TASK-08

**修改范围：**

- `README.md`
- `CHANGELOG.md`
- `DESIGN.md`
- `XRadarVerifier/`
- 必要测试

**实施：**

- 补齐第 12 节所有测试。
- 更新用户配置 RSSHub、自建实例凭据边界和 WebView 风险说明。
- 检查日志与 fixture 不含秘密。
- 运行 `./scripts/verify.sh`。

**完成标准：** 所有测试通过；`verify.sh` 返回 0；文档与实际 UI/行为一致。

### TASK-10：自定义 RSS 源规则（§13）

**依赖：** TASK-01 至 TASK-09

**修改范围：**

- `Sources/XRadarCore/Models/MonitorRule.swift`（新增 `feedURL`）
- `Sources/XRadarCore/Timeline/RSS/XRSSParser.swift`（`parseGeneric`）
- `Sources/XRadarCore/Timeline/RSS/RSSDirectFeedProvider.swift`（新增）
- `Sources/XRadarCore/Pipeline/MonitoringPipeline.swift`
- `Sources/XRadarCore/Scheduling/PollScheduler.swift`（约束 11 例外）
- `Sources/XRadarCore/Rules/KeywordMatcher.swift`（feed 规则跳过账号归属校验）
- `Sources/XRadarCore/Models/XSourceSettings.swift`（`TimelineProviderID.rssFeed`）
- `XRadar/UI/Settings/RuleEditorView.swift`、`RulesSettingsView.swift`、`FetchHistoryView.swift`
- `XRadar/App/AppModel.swift`（信源摘要）
- `XRadarVerifier/main.swift`（`checkGenericRSSFeeds`，共 29 项）
- `README.md`、`CHANGELOG.md`

**实施要点：**

- feed 规则按 `feedURL` 分组，与 X 账号规则互不混叠；同一 URL 只抓取一次。
- 空 Feed 语义与 §6.1 对齐（`emptyUnverified` / `suspiciousEmpty` / `notModified` 健康）。
- feed 规则不经过 Router，因此 `rssHubOnly` 下也不会访问 X；禁 x.com/twitter.com 域名直接作为 feed。
- 旧配置 JSON 中无 `feedURL` 字段的规则解码为 nil，行为不变。

**完成标准：** `checkGenericRSSFeeds` 通过（解析映射、HTTP 安全、基线/触发/去重/空 Feed/共存、调度门槛例外）；全套 29 项通过；`verify.sh` 返回 0；文档与实际行为一致。

---

## 15. 最终验收清单

- [x] 新安装没有可用 RSSHub 实例时明确提示配置（引导使用"测试信源"验证用户自备实例），不静默失败；配置完成前手动"立即检查"同样被禁用（存在已启用 feed 规则时除外，§13）。
- [x] v1 用户升级后规则、通知设置和历史配置均未丢失。
- [x] `rssHubOnly` 连续运行时没有任何 x.com/twitter.com 请求。
- [x] 回复和转发开关与规则语义一致。
- [x] RSSHub 显示名称不会造成账号规则不匹配。
- [x] 2xx 空 Feed 不会推进成功游标或制造"暂无新推文"的假象。
- [x] RSS 缓存延迟恢复后，三天内的新 ID仍可通知。
- [x] 首次基线不通知，跨 Provider 切换不重复通知。
- [x] 每轮每账号最多处理十条，并按发推时间倒序。
- [x] 故障实例进入冷却，不会被同轮所有账号反复请求。
- [x] 自动回退只有在用户确认后才可能触发 X WebView。
- [x] 软件界面能看到 Provider、实例、发推时间、抓取时间和失败原因。
- [x] 自定义 RSS 源规则：通用解析映射、直连安全限制（无 Cookie/单 host/禁 X 域名）、空 Feed 语义、与 X 规则共存、调度门槛例外（§13，`checkGenericRSSFeeds` 覆盖）。
- [ ] `./scripts/verify.sh` 全部通过。
