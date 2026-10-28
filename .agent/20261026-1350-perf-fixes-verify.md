# PostmanSwift 性能修复执行与复测（2026-10-26）

## 结论

- 上一轮确认的 H2（主线程 session 编码）、H3（`result.body` 常驻）、P0（`RawCodeTextView` 每次 update 重排）、P1（双面板 GeometryReader）、M2（环境变量逐键复制 Library）、M4（TabBar 非懒加载）、M1（>600 行 LazyVStack）已处理。
- 渲染线程与后台线程：数据准备已分离（解析、解码、持久化、历史写入均不在主线程）；SwiftUI 布局/AttributeGraph/Core Animation 提交与 TextKit 属于主线程，这是架构必然。UI 卡顿来自主线程布局/提交，不是“后台任务跑在主线程”。
- H1 只完成了第一步（UI 标志与搜索词窄化），完整 AppStore 拆分未做。

## 代码改动

| 文件 | 改动 |
|---|---|
| `Views/CodeText.swift` | `RawCodeTextView.resize` 增加 `ResizeState`（display 长度/wraps/lines/font/viewport），仅变化时测量；frame 写入前比较 0.5pt；display 变化时失效缓存。`sizeToFit()` 只在文本或字体变化时执行。 |
| `Views/WorkspaceView.swift` | TabBar 改 `LazyHStack`；移除包裹双面板的 GeometryReader，改为 background 尺寸探针 + `frame(height:)` 定高（`containerRelativeFrame` 的容器不含 VStack，不适用）。 |
| `Store/AppStore.swift` | `persistSession` 仅主线程抓取快照，`JSONEncoder` + 原子写移到 `sessionQueue`；`persistNow` 同步 flush；新增 `UIState`（sheet/alert/关闭确认/代码浮层/cookieRevision）；移除未使用的 `searchText`；`historySearch` 移除，改 `refreshHistory(search:)`；`ResponseRecord` 预算计入 body；超出保留集的标签把 >256KB body 写入 `session-cache/response-<tabID>.bin` 后释放内存，激活时按需读回；关标签/换响应/启动时清理落盘文件。 |
| `Store/RequestTab.swift` | `ResponseRecord` 新增 `spilledBodyURL/spilledByteCount/byteCount`；`estimatedBytes` 计入原始 body。 |
| `Views/ResponseView.swift` | 尺寸显示改用 `byteCount`（body 落盘后仍显示原始大小）。 |
| `Views/JSONTreeView.swift` | 移除 `LazyVStack` 路径，统一 eager `VStack` + 600 行分页；行数超出显示“加载更多”；展开/折叠不再重置已加载分页，并保证被操作行可见。 |
| `Views/EnvironmentAndSettingsViews.swift` | Globals/环境变量编辑改为本地草稿 + 300ms 防抖提交；切换 selection / 失焦 / 导出前 flush；避免 store→草稿回写覆盖。 |
| `Views/CompletionSupport.swift` | `VariableTextField.updateNSView` 在编辑中也会把外部绑定值写回字段（修复切标签后 URL 仍显示上一个标签地址）。 |
| `Views/RootView.swift`、`SidebarView.swift`、`App/PostmanSwiftApp.swift`、`MockAPIView.swift` | 改用 `UIState`；侧栏搜索本地化 + 防抖刷新历史。 |

## 复测中发现并修复的两个真实缺陷

1. **切标签后 URL 串台**：`VariableTextField` 在 `currentEditor() != nil` 时跳过同步，而 URL 字段在切换标签时仍保持第一响应者，导致输入框显示上一个标签的地址（模型为空，发送报 “Enter a request URL first”）。修复：外部绑定值变化时同时写入 field editor；`RequestEditorView` 加 `.id(tab.id)`。
2. **预算/恢复作用于旧标签**：`@Published` 在 willSet 阶段发值，sink 内读取 `self.activeTabID` 仍是旧值，导致切换标签时 `enforceResponseBudget` 与 `restoreResponseIfNeeded` 都作用在上一个标签上（表现为切回已落盘标签后一直停在“正在恢复大响应…”）。修复：sink 内 `DispatchQueue.main.async` 延迟一帧再读取。

## 验证证据

1. `swift build` 与 `swift build -c release` 成功；`swift test` 54/54 通过。
2. 隔离实例（独立 bundle id `com.postmanswift.qa`，数据目录 `/tmp/pn-qa2-data`）：请求工作区分栏渲染正确（上方约 55%）；发送 `postman-echo` 返回 200；Pretty/Raw/Preview 切换、滚动、新建/关闭/切换标签、环境面板均正常。
3. 大响应：`jsonplaceholder.typicode.com/comments` 158KB、3,502 行；全部展开/全部折叠/滚动无挂起，空闲 CPU 0.0–0.3%，RSS 峰值约 98MB，折叠后回落至约 62MB。
4. 环境变量防抖：45s 观测窗口内 15 次按键（分 3 批）只产生 3 次 `library.json` 写入（间隔约 2.4s），不再逐键编码整个 Library。
5. Time Profiler（附着隔离实例，30s + 35s 两次）：
   - `GraphHost.flushTransactions` 2ms / 1ms（基线 2,347ms）。
   - `CATransaction::commit` 未进入主线程热点（基线 2,905ms）。
   - `sizeThatFits` 10ms / 27ms（基线 1,071ms）。
   - `GeometryReaderLayout` 不再出现；`LazyStack.measureEstimates` 仅 1ms。
   - `NSTextView`/`NSLayoutManager` 各 1–2ms；`JSONTreeRowView.header` 4ms。
   - 负载与基线不同（本次无大媒体 payload，且 Computer Use 的 AX 查询本身占用了主线程），因此只用于证明“无布局风暴/无重复 TextKit 布局”，不做百分比直接对比。
6. 三个 1MB 响应标签（release）：
   - 生成 `session-cache/response-<tabID>.bin` 1.0MB，落盘后原标签 `result.body` 释放；
   - 切回已落盘标签：读盘 → 解码 → 构建 4,001 行树 → 约 140ms 完成恢复，不再卡在“正在恢复大响应…”；
   - 切换标签后 URL 输入框与各标签模型一致（tab1/photos、tab2/comments、tab3/photos）。

## 第二轮：P0 / H1 / M3 / M5 / M6（2026-10-26 15:30）

- **P0 新增行输入**：Headers/Params 点 Add 后无法输入的问题在隔离实例中用 AX 点击与真实坐标点击均未能复现（能聚焦、英文输入正常）。按嫌疑做了防御性修复：`VariableTextField` 用 `lastPushedText` 区分“本地输入回显”与“外部模型变更”，编辑中不再回写 field editor（避免输入法/组合串被重置，同时保留切标签 URL 同步）；Params→URL 反写改为 150ms 防抖。实测新增行连续 20 字符无丢失、URL 同步正确、切标签 URL 正确。
- **H1**：`AppStore` 与 `RequestTab` 迁到 `@Observable`；移除 `ObservableObject`/`@Published`/Combine sink，`activeTabID` 改 `didSet`，`RequestTab.draft/savedSnapshot` 用 `sessionChangeHandler` 触发会话保存。`UIState`/`RunnerState`/`MockServer` 保留 `ObservableObject`；9 个视图改 `@Environment(AppStore.self)`，3 个 tab 视图改 `@Bindable`。实测：草稿编辑后 `session.json` 1s 内更新、切标签 URL/响应正确、发送 1MB 响应正常渲染、环境面板与设置 sheet 正常。
- **M3**：新增 `ResponseBodyAccumulator`，`HTTPClient` 改 `URLSessionDataDelegate` 流式累积，超过 `AppSettings.maxInMemoryResponseBytes`（默认 32MB，设置页可改）写入 `response-cache/http-*.bin`；`HTTPResult` 增加 `bodyFileURL`/`byteCount`/`bodyPrefix`；文件型响应预览只读 2MB 前缀、跳过 PDF/图片、历史不存 body、保存直接复制文件；`RawHTTPClient` 兜底也在超阈值后落盘。单测 4 项（累积器、前缀、真实 HTTPClient+MockServer 300KB 落盘）通过；UI 实测把阈值降到 256KB 后，1MB 响应生成 1.0MB 落盘文件，界面仍显示 1MB / 4,001 行。
- **M5**：`MockServer` 改为更新时构建 method+path 索引（含 ANY 回退、禁用服务过滤），请求匹配 O(1)；新增路由索引单测。
- **M6**：不复用 JSContext（会泄漏顶层全局），改为每线程缓存 `JSVirtualMachine`、每次 run 仍新建 context；新增“两次脚本定义同名全局不泄漏”测试。
- 测试：60/60 通过；debug/release 构建通过；`dist/PostmanSwift.app` 已替换为新 Release 并 adhoc 重签（正在运行的旧实例需重启后生效）。

## 第三轮：卡死根因与 Postman 能力补齐（2026-10-26 18:30）

### 卡死根因（不是表面裁文本）

主线程样本（`sample`，100% CPU 持续 8 分钟）显示：`NSTextView.setNeedsDisplayInRect` → `_ensureLayoutCompleteForVisibleRectWithExtensionFactor` → `_NSFastFillAllLayoutHolesForGlyphRange` → `NSLayoutManager/NSATSTypesetter` 连续填充 layout holes。

设计缺陷链：
1. 读视图用 `NSTextView(usingTextLayoutManager: true)` 创建 TextKit 2，但 `configure` 里访问了 `textView.layoutManager`（以及补全定位里的 `layoutManager`）——AppKit 会**永久降级为 TextKit 1**。
2. 降级后仍启用 `allowsNonContiguousLayout`，并按行数估算出百万点级别的文档高度；TextKit 1 为保证可见区域布局，反复扩展并填充全文档 layout holes，主线程被占满。

修复：
- 移除所有读/编辑路径的 `layoutManager` 访问；补全定位改用 `NSTextView.firstRect(forCharacterRange:actualRange:)`（NSTextInputClient），不再触碰 TextKit 1。
- `RawCodeTextView.configure/resize` 加 Debug 断言：`textLayoutManager != nil`，一旦有人再次触发降级会直接暴露。
- 新增 `TextKit2Tests` 记录“访问 layoutManager 会让 TextKit 2 降级”这一事实，作为回归说明。
- 验证：1MB JSON Pretty 正常渲染，CPU 0.1–0.4%，无 layout hole 循环。

### 功能补齐

1. **选中态联动**：`activeTabID` 的 `didSet` 同步 `selectedItemID`；打开已存在的集合请求也会更新选中；切到非集合标签自动清除。截图确认侧栏高亮随活动标签变化。
2. **动态变量**：补齐 `$randomDatePast/Future`、`$randomLorem*`、银行/信用卡、货币、文件、目录、SemVer、NanoId、MAC、MIME、Avatar 等；脚本 `pm.variables.replaceIn` 通过新增 `__pmDynamic` 桥接解析 `{{$...}}`。实测 Request 标签显示解析后的 GUID/时间戳；新增 4 项单测。
3. **上次响应**：历史新增 `item_id`，`HistoryStore.latestDetail(itemID:)` 取最近一次完整响应；`openRequest` 与 `loadSession` 自动回填。重启后 Echo GET 直接显示 1MB/4,001 行响应。
4. **历史完整**：新增 `item_id`、`request_resolved_json`、`timings_json`、`response_body_path` 列；大响应复制到 `history-bodies/`，删除/清空历史同步清理；侧栏历史行显示请求名、大小、耗时；历史详情具备 Request/Timing 标签。
5. **请求参数与性能**：响应区新增 Request（实际 URL/请求头/请求体，变量/认证/Cookie 解析后）与 Timing（DNS/Socket/TLS/发送/TTFB/下载/总计/协议/远端）两个标签；`URLSessionTaskMetrics` 采集，socket 回退路径用时间戳估算；两者随历史持久化。

验证：`swift test` 66/66；debug/release 构建通过；`dist/PostmanSwift.app` 已更新并 adhoc 重签。旧历史行没有 `item_id`，因此“上次响应”只对新产生的记录生效。

## 未完成/取舍

- H1 已通过 Observation 属性级追踪完成（未拆多个 store）；`library/tabs/history/console` 仍同属 AppStore，但视图只跟踪实际读取的属性。
- M3 已完成流式+超阈值落盘；文件型响应的脚本 `pm.response` 只拿到空 body（有 console 提示），这是刻意取舍。
- M5 已完成路由索引；M6 已完成每线程 JSVirtualMachine 复用（context 仍不复用）。
- JSON 树分页 footer 未在 AX 树中稳定暴露，未能截图确认“加载更多”按钮；展开/折叠与滚动路径已验证。
- P0 的“点击完全无响应”未能在隔离实例复现，当前修复针对编辑态回写与每键重算；若仍复现，需要用户提供复现视频或输入法状态。

## 线程模型（回答）

- 后台：`performSend`（nonisolated async）、RequestBuilder、ScriptRunner、HTTPClient 回调、`documentTree`/`ensurePretty`/`Task.detached`、`TextPreparationModel` 软换行、PDF/图片解码、`library.json` 写入队列、`session.json` 写入队列、history SQLite 写入、body 落盘。
- 主线程（必须）：SwiftUI body/布局、AttributeGraph 更新、AppKit/TextKit 布局、Core Animation `CATransaction::commit`、把结果赋给 `@Published`。
- 独立进程：Core Animation render server、WindowServer、GPU 合成。
