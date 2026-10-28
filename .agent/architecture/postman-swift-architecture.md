# PostmanSwift 当前架构与性能评审

- 日期：2026-10-26
- 受众：工程负责人 / 性能与架构评审
- 决策问题：**在继续加功能前，当前架构最应该先修哪些结构性问题与性能瓶颈？**
- 视图：L1–L5 分层模块图 + 风险标注（当前状态，非目标态）
- 源文件：[postman-native-architecture.mmd](postman-native-architecture.mmd)
- 证据：`Sources/PostmanSwift/**`（当前代码），置信度 high 为主；风险等级为代码审查 + 实测推断

## 1. 阅读顺序

1. 先看 L1 UI → L2 App State → L3 Domain → L4 Persistence → L5 Frameworks 的分层。
2. 红色节点是优先处理的结构/性能问题；橙色是需要在规模上来前处理的问题。
3. 再看下方“性能与不合理点”表，按 H → M → L 排优先级。
4. 最后看“正向设计”确认哪些不要回退（媒体卡片折叠、响应预算、TextKit 2、后台解析）。

## 2. 架构主链路（一句话）

SwiftUI/AppKit 单窗口 UI 通过 `AppStore` 这个单一 `ObservableObject` 统一读写集合、标签、历史、Mock 与环境；请求由 `RequestBuilder` 组装，`HTTPClient`（URLSession）发送并整体缓冲响应，必要时降级到 POSIX `RawHTTPClient`；响应经 `DocumentTree` 解析成 JSON/XML 树，再由 `JSONTreeView` 渲染，媒体走 PDFKit/ImageIO 缩略图；脚本走 JavaScriptCore，历史写 SQLite，集合/会话/环境写 JSON 文件。

## 3. 性能与不合理点（按优先级）

| ID | 严重度 | 问题 | 证据 | 影响 | 建议 |
|---|---|---|---|---|---|
| H1 | 高 | `AppStore` 是单一 `ObservableObject`，`library/tabs/history/console/UI flags` 全在一个对象；几乎所有视图都 `@EnvironmentObject` 观察它 | `Store/AppStore.swift:97-124`；`Views/SidebarView.swift`、`WorkspaceView.swift`、`RootView.swift` 等 | 任意环境变量、Mock 文本、标签状态变化都会广播到整个 UI，导致大树/编辑器的无关重算；规模上来后卡顿来源不可控 | 拆成 `LibraryStore` / `TabStore` / `HistoryStore` / `UIState`（或用 `@Observable` 按域）；高频视图只读窄字段；热视图加 `.equatable()` |
| H2 | 高 | `persistSession()` 在主线程把**全部标签的 draft**（含大 base64 body）编码并原子写 `session.json`，由任意 tab `objectWillChange` 触发（0.8s 防抖） | `Store/AppStore.swift:301-345`；`Models/RequestModels.swift:95-102`（`rawBody`） | 编辑大 body / 多标签时，0.8s 一次的整库编码会打断输入；标签越多越慢 | 后台队列编码 + 快照；只写 dirty tabs；大 body 单独存/省略；或改为增量会话文件 |
| H3 | 高 | 响应预算只释放 `text/pretty/tree/embeddedPDFs`，**`ResponseRecord.result.body` 永远常驻**；每个标签最多 1.7MB+ | `Store/RequestTab.swift:34-50`；`Store/AppStore.swift:1191-1236` | 打开多个 base64/1.7MB 响应后内存持续增长；重启恢复后多标签仍占 body | 大 body LRU/落盘（历史 SQLite 已有 body）；只保留 active + 1 个邻近标签的 body；恢复时按需从磁盘/SQLite 读 |
| M1 | 中 | 行数 ≤600 的树改用 `VStack` 后是**全量构建**；>600 仍走 `LazyVStack` | `Views/JSONTreeView.swift:531-556` | 600 行复杂行（媒体卡、搜索过滤）会产生一次性布局尖峰；>600 仍保留曾导致卡死的懒布局路径 | 600 阈值做基准测试；>600 用 `NSTableView/NSOutlineView` 或限制媒体/嵌套展开；可把阈值降到 200 |
| M2 | 中 | 环境/Globals 编辑器每个 `TextField` 变化都 `updateEnvironment/updateGlobals` → 复制整个 `Library` 并调度持久化 | `Views/EnvironmentAndSettingsViews.swift:188-280`；`Store/AppStore.swift:269-286` | 编辑环境变量时，5.8MB library 的快照/编码被反复触发；变量多时输入延迟 | 编辑器用本地 `@State` draft，失焦/防抖 300ms 再提交；持久化只做一次 |
| M3 | 中 | `HTTPClient` 用 `dataTask` 把响应**整体缓冲成 Data** 后才返回；无大小上限/流式下载 | `Core/HTTPClient.swift:115-150` | 大文件/异常大响应会把内存翻倍；无法在下载中取消/预览 | 对 download/large body 用 streaming 写临时文件；设置最大缓冲阈值；超限提示保存 |
| M4 | 中 | 标签栏用非懒 `HStack` 渲染所有标签（`ScrollView` 只负责横向滚动） | `Views/WorkspaceView.swift:8-16` | 几十个标签时所有 chip 都构建/更新；切换标签会重排整条 | `LazyHStack` 或只渲染可视范围；标签 chip 轻量化 |
| M5 | 中 | 每个 Mock 文本编辑最终会 `scheduleMockSync` → `MockServer.update` 整体替换 services 数组 | `Store/AppStore.swift:1397-1405`；`Core/MockServer.swift:91-95` | 多个大 case body 时复制/重建路由表；虽已 300ms 防抖，仍会周期性抖动 | 路由表做不可变快照/diff，只更新变更 case；或编辑期间不同步、失焦同步 |
| M6 | 中 | 每个带脚本的请求新建 `JSContext` 并重新安装全部桥接 | `Core/ScriptRunner.swift:216-245` | Runner/批量请求或大脚本时上下文创建成本高 | 复用 JSContext/上下文池；按脚本缓存编译结果；限制脚本大小 |
| L1 | 低 | `SidebarView` 每次 body 都 `CollectionTree.flatten(collection).count`，搜索每次遍历全部集合 | `Views/SidebarView.swift:253, 549` | 大集合（189 请求）下重复 O(n) 计算 | 在 `PMCollection` 变更时预计算计数；搜索防抖/索引 |
| L2 | 低 | `variableSuggestions` 每次请求编辑器 body 计算 | `Store/AppStore.swift:1693` | 变量多时重复构造建议数组 | 按 library revision 缓存 |
| L3 | 低 | `console` 是全局无上限数组，控制台历史会持续增长 | `Store/AppStore.swift:102, 1053` | 长会话内存缓慢增长 | 限制条数（如 1000）或环形缓冲 |
| L4 | 低 | `HistoryStore.insert` 每次插入后执行 `DELETE ... NOT IN (SELECT ... LIMIT 2000)` | `Store/HistoryStore.swift:38-73` | 历史很大时每次请求多一次全表排序/删除 | 每 N 次或空闲时清理；或按 ts 索引条件删除 |

## 4. 正向设计（不要回退）

- 媒体卡片默认折叠、固定尺寸、加载占位同高：直接消除了 2026-10-26 的 `LazyStack.measureEstimates` 100% CPU 卡死；来源 `Views/JSONTreeView.swift:1590-1730`。
- 响应重载荷预算（active + 最新，其余释放 text/pretty/tree）：`Store/AppStore.swift:1191-1236`。
- Pretty 懒生成、单遍字节序列化、base64 占位：`Core/DocumentTree.swift`、`Store/AppStore.swift:1147`。
- JSON/XML 一次解析、统一树；媒体缩略图 ImageIO/PDFKit 后台渲染、NSCache 32MB 成本上限。
- 只读/编辑文本 TextKit 2；软换行与行数估算在后台；Raw 显示上限 1MB，完整内容 Copy/Save。
- 历史摘要只取元数据列，详情按需加载；SQLite 写后台。

## 5. 假设与未知

- 当前视图为**代码当前态**，不含账号/云同步（产品刻意排除）。
- 严重度基于静态审查 + 2026-10-26 的 QA 实测；未在 Instruments 下做完整 Time Profiler/Allocations 归因，H1/H2/H3 建议用 Instruments 复核先后顺序。
- Mock/历史/生成集合的行为来自现有实现，未覆盖用户自定义脚本的极端规模。
- “未发现”不等于“不存在”：网络代理、极长脚本、超大文件下载未做压力测试。

## 6. 建议的下一步（按顺序）

1. **先拆状态与持久化**：H2（后台 session 编码）→ H1（AppStore 分域/窄观察）→ H3（body 预算/落盘）。这三项是后续所有性能优化的地基。
2. **再限流高频编辑**：M2 环境变量本地草稿提交；M5 Mock 路由 diff；M4 标签懒加载。
3. **最后做大数据专项**：M1 树虚拟化、M3 流式下载；用 Instruments 验证 H1–H3 的收益。

## 7. 三句话说明

- **这张图展示**：PostmanSwift 从 SwiftUI/AppKit UI 到 AppStore、请求/解析/媒体服务、JSON/SQLite 持久化与系统框架的分层，以及当前三个高优先级性能热点。
- **这张图隐藏**：集合/环境的具体字段、每个 View 的内部实现、脚本 API 细节和 Mock 路由匹配算法；这些在需要时再下钻 L4。
- **这张图支持的决定**：先修 AppStore 广播、主线程 session 编码、响应 body 常驻，再处理高频编辑与大树虚拟化，避免继续在 UI 层打补丁。
