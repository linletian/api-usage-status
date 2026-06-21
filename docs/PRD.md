# PRD: API Usage Status — macOS 菜单栏 LLM API 用量监控工具

## 1. 项目概述

**产品名称**：API Usage Status

**项目性质**：因市面上同类软件不支持 macOS 13，故本项目为自用脚手架项目，不计划公开发布或上架 Mac App Store。

**一句话描述**：一款 macOS 菜单栏小工具，定时抓取 LLM API 平台的用量数据，同时支持周期配额型和余额型两种监控模式，并以紧凑的系统字体文字形式在菜单栏图标内直观展示，帮助开发者实时掌握 API 消费情况，避免超出配额或预算。

**平台**：macOS 13+ (Ventura 及以上)

---

## 2. 目标用户

- **本项目的唯一目标用户为开发者本人**
- 其他个人或小团队如使用本项目，需自行处理部署和适配，不在本项目支持范围内

---

## 3. 核心功能

### 3.1 菜单栏图标

- 常驻 macOS 顶部菜单栏
- **无配置状态**：未添加任何服务实例时，菜单栏显示两行动画图标 —— 首行固定 "AI"（品牌标识，居中对齐），底行循环 `%` → `%%` → `%%%`（1 秒间隔，右对齐）。文字颜色跟随用户设置的色彩模式：单色模式下为白/黑（跟随系统深色/浅色外观），彩色模式下为绿色（`#4CAF50`）。槽位宽度以最长文本（`%%%`）为基准固定，避免动画帧切换时菜单栏宽度抖动。添加第一个实例后动画自动停止，切换至正常数据槽位
- **有配置状态**：按以下规则显示槽位：
  - 每个启用的服务实例占用一个槽位，槽位高度固定 **22pt**，宽度由内容决定，**槽位数量不设上限**，所有启用实例均在菜单栏直接显示
  - 多指标实例（如 MiniMax）的每个启用指标（`displayInMenuBar == true`）在菜单栏中各自展开为独立槽位，共享同一实例简称，按 `sortOrder` + `configIndex` 排序
  - 多个槽位水平连续排列，相邻槽位之间保留 10pt 间距
  - 槽位排序按实例的 `sort_order` 字段升序排列；`sort_order` 相同时按创建时间排序
  - 用户可在设置中按指标粒度开启/关闭每个统计维度在菜单栏中的显示
  - 当启用实例过多导致菜单栏总宽度超出系统可显示区域时，macOS 系统会自行截断右侧槽位；用户可通过禁用不关注的实例控制总宽度
- **启动刷新中状态**：应用启动后尚未完成首次刷新时，所有已启用实例的槽位以灰色系统字体显示 `•••`（3 个圆点），等待首次刷新完成后切换为实际数据
- **全部禁用状态**：所有已配置实例均被禁用时，菜单栏以灰色系统字体显示 `NO API`，左键点击仍可打开面板进入设置
- **余额不可用状态**：余额型实例 API 返回 `is_available = false` 时，该实例槽位置灰，以灰色系统字体显示 `N/A`；此状态在下次刷新返回 `is_available = true` 后自动恢复
- **图标为代码动态绘制**，不依赖静态 SVG/PNG 资源文件，随数据刷新实时重绘
- 每个槽位采用**双行层叠布局**，上下分两行、各自水平居中：
  - **第一行**（上）：**显示名简称**（2 个英文字母）
  - **第二行**（下）：根据实例类型区分 —— **周期配额型**显示百分比数字（如 `82%`），**余额型**显示余额数值（如 `¥45`）
- **槽位内所有文字均使用系统字体（SF Pro Regular，8 pt）渲染**，与用量面板中最小字号（9pt system）保持同一字族，双行层叠在 22pt 高度内紧凑但可辨识。百分比数字使用等宽变体（`.monospacedSystemFont` 8pt）以保证槽位宽度稳定
- 图标色彩方案（用户可配置）：
  - **单色模式**：图标跟随 macOS 菜单栏明暗主题（黑/白），所有文字使用系统标签色（`NSColor.labelColor`）。百分比数字本身即为用量信息载体；warning 和 critical 状态触发呼吸动画：以阴影脉冲强度来表示紧急性——warning 以 4 秒周期缓慢呼吸（阴影模糊半径 0~6px，不透明度 0~0.7），critical 以 2.0 秒周期急促呼吸（阴影模糊半径 0~8px，不透明度 0~0.85）；余额型实例不触发呼吸动画
  - **彩色模式**：每个槽位独立着色，颜色规则与各服务实例绑定的阈值一致（安全/警告/严重对应不同颜色）
- 左键点击图标始终弹出用量详情面板；右键菜单栏图标：快速操作 —— 立即刷新 / 打开设置 / 退出

### 3.2 用量面板

- 点击菜单栏图标弹出浮动用量面板，按**服务实例**分组展示用量卡片。支持多指标的实例（如 MiniMax）在一张卡片内按能力桶分组展示多个指标行（如 `general` / `video` / `speech-hd` 各自显示 5h + weekly 进度条）；单指标实例延续旧版单行卡片样式
- 每张卡片展示：
  - **显示名**（用户自定义，如「MiniMax-文字」「DS-主号」）
  - **周期配额型实例**：
    - 当前周期用量（用量 / 上限）
    - 用量进度条（百分比 + 数值）
    - 下次刷新剩余时间：距下次定时刷新的分钟数。自然天/周配额型额外显示：周期剩余天数
  - **余额型实例**：
    - 当前剩余余额（金额）
    - 当日用量（本地统计值，标注「约」）
    - 日均消耗（用户可选统计周期，详见下文）
  - **See details 按钮**（卡片左下角）：
    - 仅当供应商存在对应的 Web 控制台用量详情页时显示
    - 点击后在系统默认浏览器中打开对应页面：
      - DeepSeek → `https://platform.deepseek.com/usage`
      - MiniMax → `https://platform.minimaxi.com/user-center/payment/token-plan`
      - GitHub Copilot → `https://github.com/settings/billing/ai_usage`
      - OpenCode Go → 从 UserDefaults 缓存读 workspace ID，链接到 `https://opencode.ai/workspace/<id>/go`；缓存为空时兜底到 `https://opencode.ai/zh/go`（该页带登录入口）
    - URL 映射逻辑集中在 `UsageCardView.providerURL`（按 `Provider.X.rawValue` 派发）；OpenCode 的 workspace ID 在 App 启动时由 `OpenCodeWorkspaceResolver.prewarm()` 后台扫描 `~/.local/share/opencode/log/*.log` 后写入 UserDefaults，view 层只读缓存、不阻塞 UI（详见 `docs/provider-interfaces/opencode_workspace_resolver.md`）
    - 使用无边框按钮样式，9pt 次级颜色，保持卡片视觉简洁
  - 最近一次刷新时间（卡片右下角）
- **日均消耗统计**（余额型专属，用户按实例选择统计周期，可多选）：
  - 当前自然周（周日为第一天）
  - 当前自然月
  - 倒数 7 天
  - 倒数 30 天
- **服务实例管理**：每个实例配置一个 API Key。若同一供应商有多个独立套餐/账号，可添加多个实例——每个实例为一个独立槽位，各自维护独立的配置文件、历史记录和阈值
- **错误摘要栏**：当存在刷新失败的实例时，面板顶部显示非阻塞提示，区分错误类型：
  - 网络超时/无连接："Network error, retrying in X min"
  - API 返回 401/403："API Key invalid, check settings"
  - 其他 API 错误："API error (code: XXX)"
- 手动刷新按钮

### 3.3 支持的供应商与统计维度

一个供应商可暴露多种统计维度。用户以**服务实例**为单位管理：添加时选择供应商 + 统计维度，每个实例独立配置显示名、简称、API Key 和阈值。

**P0（V1 必须实现，已有公开 API）**

| 供应商 | 统计维度 | 类型 | 数据接口 | Period / 窗口 |
|--------|----------|------|----------|---------------|
| MiniMax | 按能力桶（`model_name`，如 `general`、`video`、`speech-hd`、`music-2.6`）多指标跟踪，每个能力桶包含 5h + weekly 双窗口 | 周期配额型 | `GET /v1/token_plan/remains` | 5 小时滚动窗口 + 自然周 |
| DeepSeek | 账户余额 | 余额型 | `GET /user/balance` | 无周期重置 |
| GitHub Copilot | Premium Interactions | 周期配额型 | `GET /copilot_internal/user` | 月度配额（重置时间由 `quota_reset_date_utc` 给出） |
| OpenCode Go | 5h / Weekly / Monthly 多窗口额度（$12 / $30 / $60 上限） | 周期配额型 | 本地 SQLite（`opencode db` CLI） | 5 小时 / 自然周 / 自然月 |

> **说明**：MiniMax 的多个能力桶共用同一个 API 调用（`/v1/token_plan/remains`）。每个 `model_name`（如 `general`、`video`）作为一个独立指标（`MetricConfig`），在用量面板的一张卡片内分组展示，在菜单栏中按 `displayInMenuBar` 展开为独立槽位。同一 API Key 的多个 MiniMax 指标共享一次 HTTP 请求，`RefreshService.mapInstanceToSlotData()` 做 1:N 映射。
>
> **GitHub Copilot 说明**：使用 Classic Personal Access Token（PAT，需勾选 `copilot` scope；fine-grained PAT 不支持）。`/copilot_internal/user` 为 GitHub 内部端点，未在官方文档中正式列出，存在改版风险，详见附录 D。Pro+ / Business 无限套餐返回 `unlimited: true` 时，菜单栏槽位的已用百分比统一显示为 0%（与 MiniMax 周配额未激活的处理一致）。

**P1（已实现，非公开 API）**

| 供应商 | 统计维度 | 类型 | 数据接口 | Period / 窗口 |
|--------|----------|------|----------|---------------|
| OpenCode Go | 5h / Weekly / Monthly 多窗口额度（$12 / $30 / $60 上限） | 周期配额型 | 本地 SQLite（`opencode db` CLI） | 5 小时 / 自然周 / 自然月 |

> **说明**：OpenCode Go 不提供公开 REST API，通过本地 `opencode db` CLI 读取 `~/.local/share/opencode/opencode.db`。此供应商需要 App Sandbox 关闭（因为需要 `Process.run()`），详见 §3.6 安全说明。

### 3.4 数据刷新

- 后台定时刷新（默认 5 分钟，可配置 1–60 分钟）
- 手动下拉/点击刷新
- 应用启动时立即拉取一次
- 网络异常时自动重试（指数退避，最多 3 次）
- **刷新失败时菜单栏处理**：该实例对应的槽位显示上次成功数据（`isStale=true`），切换为灰色挖空 pill（`#D6D0A0` 圆角矩形 + 镂空文字，不降透明度——见 `ARCHITECTURE.md §7.3`），不显示错误文字或异常徽标。正常刷新成功的槽位保持纯色文字渲染（无 pill 背景）。呼吸动画在陈旧槽位上自动抑制（`updateBreathingState` 仅加入 warning/critical 的 UUID，`.error` 不在此列）。
- **刷新失败时面板处理**：每张失败实例的卡片显示**陈旧数据**：背景使用 `cardBgDim`、footer 显示 `⚠ {错误信息}` + `Cached {elapsed} ago`（基于 `slot.lastFetchedAt`）。若配额窗口过期（`cycleRemainingSeconds=0`），额外显示 `Window expired`。当天没有任何成功数据时，显示原来的「Unable to load usage data」视图。
  - "See details" 按钮始终保留——即使在失败状态用户也能跳转到 Provider 页面

### 3.5 偏好设置

通过面板内的设置图标或右键菜单打开设置窗口。偏好设置以**服务实例**为单位：

**首次使用提示**
- 应用首次启动且无配置时，菜单栏显示两行动画图标 —— 首行固定 "AI"（品牌标识），底行循环 `%` → `%%` → `%%%`（1 秒间隔）；左键点击始终打开用量面板，面板内展示空状态（Empty State），包含「添加第一个服务」按钮，点击后进入设置窗口

**服务实例管理**
- 添加实例：选择供应商。MiniMax 实例自动发现 API 返回的所有能力桶（`model_name`），用户可勾选需要跟踪的能力桶及对应窗口（5h / weekly）；OpenCode Go 实例可选择跟踪的窗口（5h / weekly / monthly）；其他供应商自动配置默认指标
- 每个实例可配置：
  - **显示名**：自定义名称（如「MiniMax-文字」「DS-主号」），**默认空**
  - **显示名简称**：2 个英文字母，用于菜单栏槽位，**默认空**
  - **指标显示开关**：在设置面板中展开实例，可为每个指标独立控制是否在菜单栏中显示（`displayInMenuBar`）
  - **排序序号**（`sort_order`）：整数，升序排列，决定菜单栏槽位和用量面板卡片的显示顺序；默认按创建顺序分配（0, 1, 2, ...），用户可在设置中拖拽调整
  - **API Key / 访问令牌**：仅实例所属供应商需要
  - **货币**：余额型实例可配置货币类型（默认 `CNY`，可选 `CNY` / `USD`）。每次 API 刷新时，若响应中包含 `currency` 字段，自动将本实例的货币设置更新为 API 返回的值，后续显示对应货币符号（`¥` / `$`）
  - **启用/禁用**：关闭后菜单栏和面板中隐藏该实例，但数据文件保留
- 一个 MiniMax API Key 添加一个实例即可跟踪所有能力桶，无需为每个能力桶单独添加实例
- 同一供应商的多个实例共享一次 API 调用（相同 API Key 去重）

**配色与阈值**（每个实例独立配置）
- **周期配额型实例**：
  - 用量百分比警告线（默认 80%，达到后槽位变黄）
  - 用量百分比严重线（默认 95%，达到后槽位变红 + 系统通知）
- **余额型实例**：
  - 剩余余额警示阈值（默认 10.00，低于后槽位变黄，货币符号根据实例货币设置自动显示）
  - 余额严重不足阈值（默认 2.00，低于后槽位变红 + 系统通知，货币符号同上）
  - 日均消耗统计周期（可多选）：当前自然周 / 当前自然月 / 倒数 7 天 / 倒数 30 天
  - 历史记录保留天数：正整数 N 保留最近 N 天，0 表示永久保留（默认 0）

**通用设置**
- **刷新间隔**：1 分钟 ~ 60 分钟（所有实例共用同一刷新周期）
- **图标色彩模式**：单色 / 彩色
- **启动项**：是否开机自启
- **通知**：达到阈值时发送 macOS 系统通知，通知本体直接包含关键详情（如实例名称、当前用量/余额、阈值状态），点击通知打开独立的用量详情面板窗口（非依附式独立窗口）

### 3.6 数据安全

- API 凭证通过 macOS Keychain Services API 存储，利用硬件安全模块（Secure Enclave）加密，任何其他应用无法读取
- Keychain 条目以 `kSecClassInternetPassword` 类型存储，关联服务名和账号标识，与 iCloud Keychain 同步由系统控制
- 内存中仅在发起网络请求时临时持有凭证字符串，请求完成后立即释放，不缓存到 UserDefaults 或文件系统
- 不收集任何用户数据，无第三方统计/埋点
- 所有网络请求直连 API 提供商服务器，使用 HTTPS 加密传输

> **⚠️ App Sandbox 状态**：自 OpenCode Go 供应商接入后，App Sandbox 已关闭。
>
> **原因**：OpenCode Go 不提供公开 REST API，唯一的数据源是本地的 `~/.local/share/opencode/opencode.db`。要读取该数据库，必须通过 `opencode db` CLI（`Process.run()`），而 macOS App Sandbox 不允许子进程创建——这是沙箱的硬性限制，无 entitlement 可例外。
>
> **影响评估**：本项目为自编译自用，仅与已知的 HTTPS API 端点通信，仅启动 `opencode` CLI 子进程，不处理不可信用户输入。实际攻击面增加在个人使用场景下可忽略不计。若将来仅使用 MiniMax / DeepSeek / Copilot 供应商而不使用 OpenCode Go，可重新开启沙箱，上述供应商无需沙箱例外。

### 3.7 余额型：当日用量本地统计

DeepSeek 等余额型 API 仅提供剩余余额，不提供当日用量接口。实行以下本地计算方案。**余额跟踪仅使用 `topped_up_balance`（充值余额），排除 `granted_balance`（赠金）**，确保赠金过期不会造成虚假消耗统计。

**计算逻辑**：

- 每次定时刷新时记录当前余额和时间戳
- 计算相邻两次余额的差值作为该时间段的消耗
- 累加自然日（00:00–23:59）内所有差值得到当日用量
- 每日零点自动清零当日累计用量
- 未被刷新覆盖的时间段视为用量为 0，不做插值估算
- 面板中当日用量标注「约」字，提示用户此为近似值

**数据持久化**：

数据存储路径（因 App Sandbox 已关闭，走用户主目录下的标准路径）：

```
~/Library/Application Support/api-usage-status/
```

> **iCloud 同步说明**：该路径不在 iCloud 同步范围内，不会随 iCloud Drive 在多台 Mac 间同步。余额型用量统计是每台设备独立维护的本地计算值，各 Mac 各自保留独立的刷新记录和当日消耗，跨设备不作合并。

文件格式：每个**服务实例**对应一个轻量 JSON 文件，路径由实例 UUID 派生。

- `latest_topped_up`：上次刷新到的充值余额字符串（来自 API 的 `topped_up_balance` 字段，排除赠金）
- `latest_topped_up_ts`：上次余额刷新的时间戳（Unix 秒）
- `last_topup_date`：最近一次检测到充值余额增加的日期（`"YYYY-MM-DD"` 格式），用于标识充值事件；若从未发生过增加则为空
- `today_date`：当前累计对应的自然日（如 `"2026-05-14"`）
- `today_usage`：当日累计消耗金额（字符串，基于 `topped_up_balance` 差值计算）
- `history`：每日消耗历史记录数组

**刷新流程（每次轮询，即时保存）**：

每次查询 API 后**立即将结果持久化写入 JSON 文件**，不依赖批量写入或定时落盘。

1. 调用余额 API，从响应中提取 `topped_up_balance` 字段作为 `current_topped_up`（若 API 返回多条货币记录，优先取 `CNY`，无 CNY 则取第一条）
2. 检查 `today_date` 是否仍为当天：若不是，则归档昨日 `today_usage` 到 `history`，重置 `today_date` 和 `today_usage` 为 0
3. 计算差值：
   - 若 `latest_topped_up` 不存在（首次刷新）：将 `current_topped_up` 写入作为基线（视为充值），本轮不计算消耗
   - 若 `current_topped_up < latest_topped_up`（正常消耗）：差值计入 `today_usage`
   - 若 `current_topped_up > latest_topped_up`（充值到账）：本轮不计入消耗，更新 `last_topup_date` 为当天日期，将 `latest_topped_up` 更新为充值后数值作为新基线；该事件不影响此前已记录的消耗轮次
   - 若余额相等：消耗为 0
4. 立即写回 `latest_topped_up`、`latest_topped_up_ts`、`today_usage`、`last_topup_date`

**日均消耗计算**：

基于 `history` 数据，用户可选以下统计周期展示日均消耗（可多选，面板中分列显示）：

| 统计周期 | 计算逻辑 | 示例（假设今天 5 月 14 日，history 有 30 天数据） |
|----------|----------|------|
| 当前自然周 | 周日 ~ 今天 | 5/11 ~ 5/14 的总消耗 ÷ 天数 |
| 当前自然月 | 本月 1 日 ~ 今天 | 5/1 ~ 5/14 的总消耗 ÷ 天数 |
| 倒数 7 天 | 过去 7 个自然日 | 5/8 ~ 5/14 的总消耗 ÷ 7 |
| 倒数 30 天 | 过去 30 个自然日 | 4/15 ~ 5/14 的总消耗 ÷ 30 |

- 若某天无记录（应用未运行），该天用量为 0，不影响除法分母
- 计算在每次刷新完成后即时更新，无需持久化到 JSON 文件

**历史记录**：

历史记录**默认永久保留**，不做自动清理。在偏好设置中提供「保留最近 N 天」输入项，用户可手动输入天数触发清理：

- 默认值：`0`（即永久保留，不清理）
- 用户输入正整数 N 后，下次轮询结束时自动删除 `N` 天之前的 `history` 条目

历史记录存储为对象数组（便于未来扩展时间精度等字段）：

```json
{
  "latest_topped_up": "98.50",
  "latest_topped_up_ts": 1715680000,
  "last_topup_date": "2026-05-10",
  "today_date": "2026-05-14",
  "today_usage": "1.50",
  "history": [
    { "date": "2026-05-14", "usage": "1.50" },
    { "date": "2026-05-13", "usage": "4.20" },
    { "date": "2026-05-12", "usage": "3.80" }
  ]
}
```

> **安全说明**：JSON 文件中不含 API 凭证本身，仅有数值型用量数据。凭证始终仅存在于 Keychain 中。

### 3.8 配置数据持久化

实例元数据（供应商、统计维度、显示名、阈值等）和全局设置统一存储在一个 JSON 文件中，路径同 3.7 节（`~/Library/Application Support/api-usage-status/`）。

文件名：`instances.json`

```json
{
  "instances": [
    {
      "uuid": "550e8400-e29b-41d4-a716-446655440000",
      "provider": "minimax",
      "dimension": "text_model_5h",
      "display_name": "MiniMax-文字",
      "short_name": "MX",
      "api_key_ref": "minimax-token-plan",
      "enabled": true,
      "sort_order": 0,
      "currency": null,
      "thresholds": {
        "usage_warning_percent": 80,
        "usage_critical_percent": 95
      }
    },
    {
      "uuid": "550e8400-e29b-41d4-a716-446655440001",
      "provider": "deepseek",
      "dimension": "balance",
      "display_name": "DS-主号",
      "short_name": "DS",
      "api_key_ref": "deepseek-main",
      "enabled": true,
      "sort_order": 1,
      "currency": "CNY",
      "thresholds": {
        "balance_warning": 10.00,
        "balance_critical": 2.00,
        "avg_daily_periods": ["current_week", "current_month", "last_7_days", "last_30_days"],
        "history_retention_days": 0
      }
    }
  ],
  "settings": {
    "refresh_interval_minutes": 5,
    "color_mode": "color",
    "launch_at_login": false,
    "notifications_enabled": true
  }
}
```

**字段说明**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `uuid` | string | 实例唯一标识，创建时生成 UUID v4，不可变 |
| `provider` | string | 供应商标识，如 `minimax`、`deepseek` |
| `dimension` | string | 统计维度标识，如 `text_model_5h`、`non_text_daily`、`weekly_total`、`balance` |
| `display_name` | string | 用户自定义显示名（如「MiniMax-文字」） |
| `short_name` | string | 2-3 个大写英文字母或数字简称（如 MX、MAX、OC5），用于菜单栏槽位左侧标识 |
| `api_key_ref` | string | API Key 引用名。相同 `api_key_ref` 的多个实例共享同一把 Key，刷新时合并为一次 HTTP 请求。API Key 本身存储在 Keychain 中，以 `api_key_ref` 为查找标识 |
| `enabled` | boolean | 实例启用状态。禁用后菜单栏和面板隐藏该实例，但数据文件保留 |
| `sort_order` | integer | 排序序号，升序排列，决定菜单栏槽位和面板卡片的显示顺序。`sort_order` 相同时按创建时间排序 |
| `currency` | string \| null | 余额型实例的货币类型（`"CNY"` / `"USD"`）。周期配额型实例为 `null`。每次 API 刷新时，若 API 返回多条货币记录，优先取 `CNY` 记录，否则取第一条，并自动更新为本字段 |
| `thresholds` | object | 实例级阈值配置。周期配额型含 `usage_warning_percent` / `usage_critical_percent`；余额型含 `balance_warning` / `balance_critical` / `avg_daily_periods` / `history_retention_days` |
| `settings` | object | 全局设置（刷新间隔、色彩模式、开机自启、通知开关），所有实例共用 |

> **注意**：`instances.json` 仅存储配置元数据，不含 API 凭证（Keychain 管理）和用量历史数据（各实例独立 JSON 文件，见 3.7 节）。
> 
> **实例删除**：删除实例时同步清理：① `instances.json` 中移除该实例条目；② 删除该实例对应的余额用量历史 JSON 文件（路径由实例 `uuid` 派生）；③ 若删除后无其他实例引用同一 `api_key_ref`，则一并删除 Keychain 中对应的 API Key 条目。

---

## 4. 用户交互流程

```
[菜单栏图标] ──左键单击──▶ [用量面板（浮动窗口）]
  │                                  ├─ 错误摘要栏（如有刷新失败）
  │  无配置: 显示 "AI" + "%" 循环动画  ├─ 各服务实例用量卡片
  │  N 实例: 顺序排列 N 个槽位        │   ├─ 周期配额型：用量/上限
  │  配额型槽位: 简称+百分比数字       │   └─ 余额型：余额 + 当日用量(~)
  │  余额型槽位: 简称+余额数字        │       + 日均消耗（可选周期）
  │  （每槽宽度由内容决定，10pt 间隔）  ├─ [刷新按钮]
  │                                  └─ [设置入口] ──▶ [设置窗口]
  ├──右键──▶ [右键菜单]                                        ├─ 服务实例管理
  │           ├─ 立即刷新                                        ├─ 配色与阈值
  │           ├─ 打开设置                                        ├─ 图标模式
  │           └─ 退出                                            └─ 通用设置
  └──通知──▶ 点击通知 ──▶ 打开独立用量面板窗口（NSPanel）
```

---

## 5. 非功能性需求

- **性能**：后台刷新 CPU 占用 < 1%，内存常驻 < 50MB
- **可靠性**：网络异常时优雅降级，保持上次数据的展示
- **兼容性**：macOS 13.0+
- **语言**：仅英文，不引入本地化框架


---

## 6. 风险与假设

| 风险 | 缓解措施 |
|------|----------|
| Copilot / MiniMax 用量接口可能变更 | 关注官方 API 变更日志，版本更新时快速适配 |
| Copilot 使用的 `/copilot_internal/user` 为非官方文档端点 | parser 硬依赖核心字段（`entitlement` / `remaining` / `percent_remaining` / `unlimited` / `quota_reset_date_utc`），这些字段缺失或类型不符时**抛 `RefreshError.parsingError`**（不静默降级为 0，避免误触发 100% critical 告警）；次要字段（如 `overage_count`，目前未使用）缺失时降级为 0；如端点改版，单点修改 `CopilotResponseParser` 即可 |
| DeepSeek 余额接口变更 | 同上，定期关注 DeepSeek 开放平台公告 |
| macOS 沙盒限制 | 为支持 OpenCode Go 供应商（需 `Process.run()` 执行 `opencode` CLI），App Sandbox 已关闭。MiniMax / DeepSeek / Copilot 供应商在沙箱开启或关闭下行为一致。若移除 OpenCode Go 支持，可重新开启沙箱。Entitlements 保持精简：`com.apple.security.network.client`（发起网络请求）、`com.apple.security.files.user-selected.read-only`（可选，读取本地配置） |
| 用户 API 凭证安全担忧 | Keychain 存储，本地处理，计划开源 |
| 启用实例过多导致菜单栏总宽度超出系统可显示区域 | 不设硬性槽位数上限；当 macOS 自行截断右侧槽位时，用户可通过禁用不关注的实例缩短总宽度，或在用量面板中查看全部 |
| 余额型当日用量统计存在误差（刷新间隔内可能发生多次消费） | 面板标注「约」字；支持用户调高刷新频率提升精度 |

---

## 7. 成功指标

- 应用启动到首次用量展示 < 3s
- 后台 CPU 占用 < 1%
- 崩溃率 < 0.5%
- 设置到可用的操作步骤应尽量简洁（目标：输入凭证 → 保存 → 自动展示），实际步骤数需与代码复杂度平衡，不作为强制硬性指标
- 菜单栏图标在暗色/亮色菜单栏下均清晰可辨

---

## 8. 自用部署要求

本项目为脚手架项目，仅在本机编译运行，不走公开发布流程。以下是 macOS 自用部署的关键点：

### 8.1 不需要的

| 项目 | 原因 |
|------|------|
| Apple Developer 付费账号（$99/年） | ad-hoc 签名即可运行自编译应用 |
| Notarization（公证） | 仅分发/上架需要，自用无需 |
| Mac App Store 上架 | 脚手架项目 |
| TestFlight | 同上 |
| Provisioning Profile | 自用无需配置 |

### 8.2 实际需要的

| 事项 | 方案 |
|------|------|
| **代码签名** | Xcode Debug Build 默认使用 ad-hoc 签名（`-`），无需额外配置；如需手动签名：`codesign --force --deep --sign - YourApp.app` |
| **Gatekeeper 绕过** | 首次运行时右键点击应用 →「打开」，或执行 `xattr -cr YourApp.app` 去除隔离标记 |
| **App Sandbox（可选）** | 当前为支持 OpenCode Go 供应商而关闭（详见 3.6 节说明）。若不使用 OpenCode Go，可在 Xcode → Target → Signing & Capabilities → 开启 App Sandbox，并配置以下 entitlements：<br>- `com.apple.security.network.client`：发起 HTTPS 网络请求<br>- `com.apple.security.files.user-selected.read-only`：读取用户手动选择的文件（可选，用于将来导入/导出配置） |
| **Keychain 存储** | ad-hoc 签名下可正常读写 Keychain，无需额外权限 |
| **开机自启** | `SMAppService`（macOS 13+）在 ad-hoc 签名下正常工作 |

### 8.3 本地部署流程

```bash
# 1. 克隆项目
git clone <repo-url> && cd api-usage-check

# 2. 编译
xcodebuild -project APIUsageStatus.xcodeproj -scheme APIUsageStatus -configuration Release build

# 3. 将 .app 拖入 /Applications 或直接运行
open -a APIUsageStatus

# 4. （可选）设为开机自启：在应用设置中勾选「Launch at Login」
```

---

## 附录 A：DeepSeek 余额查询接口

**来源**：https://api-docs.deepseek.com/zh-cn/api/get-user-balance

```
GET /user/balance
```

**响应示例**：

```json
{
  "is_available": true,
  "balance_infos": [
    {
      "currency": "CNY",
      "total_balance": "110.00",
      "granted_balance": "10.00",
      "topped_up_balance": "100.00"
    }
  ]
}
```

**字段说明**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `is_available` | boolean | 当前账户是否有余额可供 API 调用 |
| `balance_infos[].currency` | string | 货币类型，`CNY`（人民币）或 `USD`（美元） |
| `balance_infos[].total_balance` | string | 总的可用余额（赠金 + 充值余额） |
| `balance_infos[].granted_balance` | string | 未过期的赠金余额 |
| `balance_infos[].topped_up_balance` | string | 充值余额 |

**与本产品的关联**：
- `topped_up_balance` 用于菜单栏图标余额数值显示和面板余额展示（仅跟踪充值余额，排除赠金，避免赠金过期造成消耗统计偏差）
- `is_available` 为 `false` 时，该实例槽位进入「余额不可用」状态（见 3.1 菜单栏状态定义）
- 本地日用量统计基于相邻两次 `topped_up_balance` 差值计算
- 若 `balance_infos` 返回多条记录（同时包含 CNY 和 USD），优先取第一条 `currency = "CNY"` 的记录；若无 CNY 则取第一条

---

## 附录 B：MiniMax Token Plan 用量查询接口

**来源**：https://platform.minimaxi.com/docs/token-plan/faq

```
GET https://www.minimaxi.com/v1/token_plan/remains
Authorization: Bearer <Token Plan Key>
```

**Token Plan Key 说明**：
- Token Plan Key 与普通按量计费 API Key 相互独立
- 同一把 Key 可用于 Token Plan 订阅额度 + Credits

**计费机制**：

| 模型类型 | 重置机制 | 说明 |
|----------|----------|------|
| 文本模型（M2.7 等） | 5 小时滚动窗口 | 过去 5 小时内总请求量，5 小时前额度自动释放 |
| 非文本模型（TTS HD / 视频 / 音乐 / 图像） | 每日配额 | 每日自动重置 |
| API-vlm（多模态理解） | 同文本模型 | 每次请求扣除 3 次 M2.7 请求 |
| Credits | 按量补充 | 超出 Token Plan 额度部分由 Credits 自动支付 |

**响应格式**（已验证）：

响应体是一个 `model_remains` 数组，每个元素代表一个模型的配额状态。**每个模型都是独立的监控维度**，用户可按需选择要监控的模型。

```json
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_status": 1,
      "current_interval_remaining_percent": 99,
      "start_time": 1781265600000,
      "end_time": 1781280000000,
      "remains_time": 14369778,
      "current_weekly_status": 3,
      "current_weekly_remaining_percent": 100,
      "weekly_start_time": 1780848000000,
      "weekly_end_time": 1781452800000,
      "weekly_remains_time": 187169778
    }
  ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
```

**字段说明**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `model_name` | string | 模型名称，如 `"general"`、`"video"`、`"music-2.6"` 等。每个值对应一个独立维度 |
| `current_interval_status` | int | 5h 区间配额状态（`1` = 生效，其他值视为未激活） |
| `current_interval_remaining_percent` | number | 5h 区间剩余百分比（0-100） |
| `start_time` / `end_time` | int64 | 5h 区间时间窗口（毫秒时间戳） |
| `remains_time` | int64 | 区间内剩余时间（毫秒） |
| `current_weekly_status` | int | 周配额状态（`1` = 生效，其他值视为未激活） |
| `current_weekly_remaining_percent` | number | 周剩余百分比（0-100） |
| `weekly_start_time` / `weekly_end_time` | int64 | 本周时间窗口（毫秒时间戳） |
| `weekly_remains_time` | int64 | 本周剩余时间（毫秒） |

> 旧字段 `current_interval_total_count` / `current_interval_usage_count` 等已弃用，实测恒为 0，不再使用。

**百分比计算规则**：

- `current_interval_status == 1` 时：`百分比 = 100 - current_interval_remaining_percent`
- `current_interval_status != 1` 时：该模型 5h 区间未激活，`百分比 = 0`
- `current_weekly_status == 1` 时：额外计算周百分比 `100 - current_weekly_remaining_percent`

**内部维度标识符**：

每个 `model_name` 值直接作为 `Instance.dimension` 使用，不再使用固定的 `text_model_5h` / `non_text_daily` 等枚举值。

> **注意**：MiniMax Token Plan 面向个人开发者的交互式使用场景，生产环境建议使用按量付费。

---

## 附录 C：OpenCode Go 用量查询（V1 已支持）

> **状态**：V1 已支持。通过 shell 调用本地 `opencode` CLI 读取 SQLite 数据库实现，详见 `docs/provider-interfaces/opencode_go.md`。

**来源**：https://opencode.ai/docs/go/

**现状**：OpenCode Go 是 OpenCode 提供的低价订阅方案（$10/月），内置以下用量限制：

| 限制维度 | 金额上限 |
|----------|----------|
| 5 小时 | $12 |
| 每周 | $30 |
| 每月 | $60 |

- 用量以美元金额计量（非 Token 数），不同模型消耗速率不同
- OpenCode 会将会话历史和 cost 数据写入本地 SQLite（`~/.local/share/opencode/opencode.db`）
- 本项目通过 `opencode db "<SQL>" --format json` 子命令读取该数据库，无需远程 HTTP API
- 超出限制后，若用户开通了 Zen 余额自动补充功能，可继续使用

**实现方式**：

| 项目 | 说明 |
|------|------|
| 数据源 | 本地 SQLite，`SELECT … FROM message WHERE providerID='opencode-go' AND role='assistant'` |
| 调用方式 | `ShellProcessRunner` 执行 `opencode db <SQL> --format json` |
| 三窗口 | 5h（滚动，最旧消息+5h）/ Weekly（UTC 周一重置）/ Monthly（锚定首次使用日） |
| 无 API Key | 无需远程凭证，但需 `opencode` CLI 已安装且已认证 |
| 上限常量 | `OpenCodeGoLimits` 硬编码 $12/$30/$60，上游调价时需同步修改 |

**OpenCode Zen** 同为按量付费余额模式，亦无公开余额查询 API，V1 暂不支持。

> **对本项目的影响**：OpenCode Go 已通过 `OpenCodeSupplier` 接入，无需等待官方发布公开 API。Zen 余额模式暂不支持，需等待后续迭代。

---

## 附录 D：GitHub Copilot 用量查询接口

**来源**：`docs/provider-interfaces/copilot.md`（详细调研与设计取舍）

```
GET https://api.github.com/copilot_internal/user
Authorization: Bearer <Classic PAT, 需要 "copilot" scope>
Accept: application/json
```

**PAT 说明**：
- 必须使用 **Classic** Personal Access Token，在 https://github.com/settings/tokens 创建，勾选 `copilot` scope
- Fine-grained PAT **不支持**（该 token 类型没有 `copilot` scope）
- 该端点不要求 username，仅凭 token 鉴权
- `/copilot_internal/user` 为 GitHub 内部端点，未在官方文档中正式列出（详见 6 节风险表）

**响应示例**：

```json
{
  "copilot_plan": "pro",
  "quota_reset_date_utc": "2026-07-01T00:00:00Z",
  "quota_snapshots": {
    "premium_interactions": {
      "entitlement": 300,
      "percent_remaining": 73.33,
      "remaining": 220,
      "unlimited": false,
      "overage_count": 0,
      "overage_permitted": false
    }
  }
}
```

**字段说明**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `copilot_plan` | string | 套餐名称，如 `"pro"`、`"pro_plus"`、`"business"` 等 |
| `quota_reset_date_utc` | string (ISO 8601) | 下次配额重置时间（UTC），用于计算剩余周期 |
| `quota_snapshots.premium_interactions.entitlement` | number | 月度配额上限 |
| `quota_snapshots.premium_interactions.remaining` | number | 剩余次数 |
| `quota_snapshots.premium_interactions.percent_remaining` | number | 剩余百分比（0-100，首选渲染字段） |
| `quota_snapshots.premium_interactions.unlimited` | boolean | true 时为无限套餐，菜单栏槽位已用百分比统一显示 0% |
| `quota_snapshots.premium_interactions.overage_count` | number | 超额次数（保留字段，目前不参与菜单栏渲染） |
| `quota_snapshots.premium_interactions.overage_permitted` | boolean | 是否允许超额（保留字段） |

**与本产品的关联**：

- **统计维度**：仅暴露 `premium_interactions` 一个固定维度，作为 `Instance.dimension` 使用
- **周期类型**：月度配额型，重置时间直接取 API 返回的 `quota_reset_date_utc`，无需本地计算
- **百分比计算规则**：
  - `unlimited == true` 时：菜单栏槽位已用百分比 = `0`（与 MiniMax 周配额未激活的语义一致，避免无限套餐误触发阈值）
  - `unlimited == false` 时：已用百分比 = `100 - percent_remaining`
- **覆盖套餐**：Free / Pro / Pro+ / Business / Enterprise 全部适用，端点对所有套餐通用
- **不在本次实现范围**：GitHub Billing API（`/users/{username}/settings/billing/premium_request/usage`）的双探针模式，本项目自用 Personal 套餐，单 Internal API 已足够

**配置流程（用户视角）**：

1. 到 https://github.com/settings/tokens 生成 Classic PAT，勾选 `copilot` scope
2. 应用 → Settings → Add Instance → Provider 选 "GitHub Copilot" → Dimension 选 "Premium Interactions" → 粘贴 PAT
3. 菜单栏出现新条目，首次刷新后显示本月用量百分比

