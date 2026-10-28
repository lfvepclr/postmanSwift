# PostmanSwift 性能重构 + 嵌套文档查看器 + 6 项交互修复

## Context

PostmanSwift 是 `/Users/spencer/workspace/qoder/postman/PostmanSwift` 下的本地 SwiftUI/AppKit 原生 API 客户端。当前用真实用例（`/Users/spencer/workspace/qoder/pigeon/test_case`）会卡：

- `resp_1.json` 1.7MB JSON（内含 base64 PDF）、`xml_json.txt` 1.7MB XML（`<content>` 内是 1.66MB JSON）、`json_in_json.json` 87KB（`body` 内嵌 86KB JSON）、`base64_json.json` 19KB（嵌套 JSON + 7.4KB PDF + 7.6KB PNG）。
- 用户诉求：预览/滚动/历史回看要流畅、内存不暴涨；支持 JSON-in-JSON、XML-in-JSON、JSON-in-XML 逐层展开，内嵌 base64 PDF/图片在原位置显示；顺带修 6 个交互问题并自行端到端验证。

已加载并遵循 `swiftui-performance`（先代码审查、Release 测量、窄化状态、稳定 identity、重活移出 body）与 `axiom-performance`（xctrace/Allocations/Hangs、String/Array/COW 成本）。`apple-xcode-workflow` 是构建/工具链流程；本机未安装 `swift-ios-skills`，其能力由 `ios-application-dev`/上述两个技能覆盖。

## 代码证据（当前实现的问题点）

1. **大文本反模式**
   - `Views/CodeText.swift:96-156` 每次更新对全文 `Array(text.utf8)` 再逐字节扫描/软换行；1.7MB 在主线程 `updateNSView` 完成。
   - `CodeText.swift:20-60` 用 `NSTextView.scrollableTextView()`（TextKit 1），1.7MB 换行后约 1.4 万行，布局成本高。
   - `Utilities/SyntaxHighlighter.swift:77-155` 对 ≤400KB 文本跑多条正则；大段 base64 单行也会被高亮。
2. **同一响应解析 3 次**
   - `Store/AppStore.swift:899-901` 依次 `prettyBody`（内部 `JSONSerialization` + 逐 Character 拼接，`Utilities/URLUtilities.swift:117-171`）、`jsonTree`、`PDFExtractor.extract`（再 `JSONSerialization` 一次，`Core/PDFExtractor.swift:39-42`）。
   - `pretty` 与 `text` 都常驻，加上 `tree` 与 `result.body`，单响应约 4 份大内容；多开历史标签会线性膨胀。
3. **树的模型能力不足**
   - `Core/JSONTree.swift:10-32` 只有 object/array/string/number/bool/null；字符串只做 base64 检测。嵌套 JSON/XML 只显示截断字符串。
   - `Views/JSONTreeView.swift:34-111` 只处理 PDF/image；`stringPreview` 用 `value.count`（O(n) 字符计数）处理 1.6MB 字符串；toggle 在主线程整棵重排（`JSONTreeView.swift:223-230`）。
4. **Mock 编辑器**
   - `Views/MockAPIView.swift:407-411` 响应体用 `CodeTextEditor`；`caseBinding`（`MockAPIView.swift:464-485`）每次按键回写 `store.updateMockCase`（`AppStore.swift:1237-1243`，触发 `persist()` + `syncMockServer()`），整页 SwiftUI 重算。
   - `Views/CompletionSupport.swift:159-175` 每次按键复制 caret 前全文并反向搜 `{{`；大文本上放大了卡顿。
   - 新增 case 后没有主动 `makeFirstResponder`，响应体编辑器无光标。
5. **代码片段弹窗**
   - `tab.showCode` 是 `RequestTab` 的 `@Published`（`Store/RequestTab.swift:58`）：点开会让 `ResponseView`（`@ObservedObject tab`）一起重算，叠加 `CodeSnippetView` 内联调用两次 `store.codeSnippet`（`Views/RunnerView.swift:229`，`AppStore.swift:1087-1106`）。`Close` 只 `dismiss()` 不清状态。
6. **布局穿透与窗口**
   - `Views/RootView.swift:10-27` 用 `NavigationSplitView`；macOS 26 上侧栏为浮层，detail 的 TabBar 可滑到侧栏下面。
   - `Views/Components.swift:193-207` 的 `DragView.mouseDown` 只做 `performDrag`，双击不会 `zoom`。

## 目标（验收指标，Release 构建）

| 项 | 目标 |
|---|---|
| 1.7MB JSON/XML 打开 Preview | 解析+建行 ≤300ms（后台），首帧 ≤400ms |
| 树滚动/展开 | 无 >200ms 主线程卡顿；连续 3 轮×200 次滚动不卡死 |
| Raw/Pretty 切换 | ≤150ms 出首屏；1.7MB 可正常滚动 |
| 内存 | 单响应增量 RSS ≤150MB；6 个重响应标签切换后 ≤300MB 且 20 轮切换不增长 |
| Mock 粘贴 100KB base64 | 文本出现 ≤300ms；后续键入延迟 ≤50ms |
| 代码片段弹窗 | 打开/关闭 ≤150ms，可关闭 |
| 稳定性 | 0 crash/hang 报告；空闲 CPU ≈0% |

## 实施计划

### Phase 0.0：方案归档（执行第一步）

- 将本方案原样保存到项目内：
  `/Users/spencer/workspace/qoder/postman/PostmanSwift/.agent/<yyyyMMdd-HHmm>-postman-native-perf-plan.md`
  （以写入时刻为准，例如 `20261025-2130-postman-native-perf-plan.md`；目录不存在则创建）。
- 后续实现过程中的基线/对比指标追加到同目录 `<yyyyMMdd-HHmm>-perf-report.md`，不污染源码仓库的 `Sources/`。

### Phase 0：基线 + 测量工具（先测后改）

- 保留当前 release 副本 `/tmp/PostmanSwift-baseline.app`，记录同一用例的 RSS、滚动主线程最大停顿、Mock 粘贴耗时。
- 新增临时 `Sources/PostmanSwift/App/PerfQAHarness.swift`（env `POSTMANSWIFT_PERF_QA=1`，最终删除）：
  - 从 `POSTMANSWIFT_QA_FIXTURES` 读取 5 个用例，构造 `HTTPResult` 注入标签。
  - 用 `DispatchSourceTimer` 16ms 心跳测主线程最大间隔；直接驱动最大 `NSScrollView` 偏移压测；`task_info` 采样 RSS。
  - 用 `window.contentView.cacheDisplay` 自截图到 `/tmp/pn-shot-*.png`（无需录屏权限），覆盖 Preview/Raw/Pretty、嵌套展开、Mock 粘贴、代码弹窗、环境面板、TabBar。
  - 日志写 `/tmp/pn-perf.log`。
- 如需 trace：`xcrun xctrace record --template 'Time Profiler' --attach PostmanSwift --time-limit 20s --output /tmp/pn.trace`（同时可 `Allocations`、`Hangs`）；卡死时 `sample <pid> 5 -file /tmp/pn-sample.txt`。

### Phase 1：统一文档模型与解析（Core）

改动：`Core/JSONTree.swift`，新增 `Core/DocumentTree.swift`（或并入 JSONTree.swift）。

- `JSONTreeNode` 增加 `.xmlElement(XMLTreeElement)` 与 `.xmlText(String)`；`XMLTreeElement` 含 name、有序/稳定 attributes、children。
- 新增 `DocumentTreeBuilder`：按 mime + 头部判定 JSON/XML；JSON 复用现有零拷贝字节解析器，XML 用 Foundation `XMLParser`（SAX）一次构建，处理实体、CDATA、注释、声明，失败则回退原始字符串。
- 新增 `PayloadClassifier`（只做前缀快判，不做全量解析）：
  - base64 PDF（`JVBERi0` / `data:application/pdf`）
  - base64 图片（`iVBORw0KGgo`、`/9j/`、`R0lGOD`、`UklGR` / `data:image/*`)
  - JSON（trim 后首字符 `{`/`[`、末字符 `}`/`]`、长度 ≥2）
  - XML（trim 后 `<` + 第二位字母/`/`/`?`/`!`）
  - URL（http/https）、普通文本
- 所有长度/字节判断改 `utf8.count`（O(1)），替换 `Base64PDF.byteCount`、`Base64Image.byteCount`、`mediaPreview`、`stringPreview`、`PDFPagePreviewLoader.key`、`ImagePreviewLoader.key` 里的 `String.count`。
- 新增 `PayloadParseCache`：`[path: JSONTreeNode]`，仅对展开的嵌套载荷按需解析；>512KB 的载荷在 `Task.detached` 解析，UI 先显示“解析中”。
- 新增 `DocumentSerializer`：
  - `prettyJSON(root)`：单遍 `[UInt8]` 输出、保留 key 顺序与数字字面量；base64 PDF/IMG 替换为 `<base64 … N KB>` 占位符。
  - `prettyXML(root)`：按树缩进输出，不重新扫描原文。
  - 不调用 `JSONSerialization`，不逐 `Character` 拼接；`JSONFormatting.prettyPrinted` 改为调用它（保持旧测试契约）。

### Phase 2：树渲染性能 + 嵌套展开（Views/JSONTreeView.swift）

- 行类型扩展：`embeddedJSON`、`embeddedXML`、`xmlOpen/xmlClose/xmlAttribute/xmlText`；保留 PDF/IMG 卡片，可在任意深度出现。
- Flatten 规则：
  - 字符串先分类；PDF/IMG 生成卡片行；JSON/XML 字符串生成“类型徽章 + 大小 + 预览”行，展开时把解析结果的子节点插到原位置。
  - XML 元素行显示 `tag`、属性摘要、子节点数；属性单独成行；文本节点分类后再判断 JSON/XML。
  - 行上限 4000；超限提示保留。
- 默认展开：根 + 2 层；含媒体的容器必展开；嵌套 JSON/XML 仅当 ≤256KB 且深度 <3 自动展开，大载荷保持折叠（首屏快，用户再点）。
- 性能：
  - 行颜色/字体改 `static let`；缩进用单一 `padding` + 每 4 层一条引导线，去掉每行 `ForEach` 画多条线。
  - `JSONTreeView: Equatable`（比较 `presentation.id`）并在父视图 `.equatable()`，避免标签其他状态变化时重算 4000 行。
  - toggle 后重排保持在 ≤4000 行的主线程；嵌套大载荷解析走后台并在完成后替换 rows。
- 功能补齐（参考 `nested-json-viewer`）：
  - 工具栏：搜索（只匹配 key/预计算 preview，200ms 防抖）、全部展开/折叠。
  - 右键：复制值、复制键名、复制路径、复制原始 JSON 片段。
  - 类型徽章：JSON / XML / PDF / IMG / URL；截断显示 `(N chars)`。
- 复用现有 PDF/Image 卡与查看器，缓存改 `NSCache` 带 `totalCostLimit`（PDF/图片 data + 缩略图各 32MB）。

### Phase 3：响应链路与内存预算（Store / ResponseView / CodeText）

- `Store/AppStore.swift`
  - `performSend`：只解析一次 `DocumentTreeBuilder`；`pretty` 不再预生成；`PDFExtractor` 仅用于“无树”的纯文本响应；`PDFExtractor` 去掉整段 `JSONSerialization`，限制总解码 ≤32MB。
  - `jsonTree` 改名 `documentTree`，JSON/XML 都返回 presentation；历史 `prepareHistoryPayload` 同步改造（不预生成 pretty）。
  - `Pretty` 懒生成：`ResponseRecord.pretty` 为空时，在用户切到 Pretty 的后台生成并回填；`@Published isPreparingPretty` 驱动加载态。
  - 内存预算：`enforceResponseBudget(activeTabID:)`，重载荷 = text+pretty+tree；总预算 64MB / 最多 2 个标签，超出时释放非活动标签的 text/pretty/tree（保留 `result.body` 摘要）；切回时用 body 后台重建并显示“正在恢复大响应…”。在 `activeTabID` 变化、发送完成、历史加载后调用。
  - `codeSnippet` 状态移出 `RequestTab`：`@Published var codeSnippetTabID: UUID?` + open/close。
  - `updateMockCase` 增加 300ms 防抖的 `syncMockServer`；持久化仍由现有 350ms 防抖负责。
- `Store/RequestTab.swift`：删除 `showCode`；`ResponseRecord` 增加 `isEvicted`/`estimatedBytes`。
- `Views/ResponseView.swift`
  - Preview：有 tree 就渲染（JSON/XML）；`Raw`/`Pretty` 使用新的 `CodeText` 包装（后台准备 + TextKit 2）。
  - Pretty 未生成时显示加载态；base64 占位提示保留。
  - 恢复大响应时显示占位/进度。
- `Views/CodeText.swift`（重点）
  - 只读查看器：显式 `NSTextView(usingTextLayoutManager: true)`（TextKit 2，视口布局）；`layoutManager?.allowsNonContiguousLayout = true` 兜底。
  - 新增 `CodeText` SwiftUI 包装：软换行/截断在后台计算并缓存（key: text 长度 + 首尾片段 + 模式）；>512KB 不执行语法高亮；>128KB 单行自动关闭宽度跟踪、启用横向滚动，避免测量整行。
  - 编辑器：`CodeTextEditor` 增加
    - 150ms 防抖回写 Binding（结束编辑/失焦立即 flush）；
    - `focusToken` 变化时 `makeFirstResponder` + 滚动到光标（修复新增 case 无光标）；
    - 大文档（>200KB 或当前行 >4KB）跳过补全与高亮；
    - 补全只检查 caret 前 200 字符，粘贴（增量 >4096）不触发补全；
    - 超大文档关闭 undo/自动补全，`isRichText=false`、关闭各类自动替换。
- `Views/ResponseView.swift` 的 `limited` 保持 2MB/8MB 上限不变，避免文本前缀复制产生额外 8MB 副本（仅在超限时截断）。

### Phase 4：六项交互修复

1. **Mock API 新增后无光标 + 超大字符串编辑**
   - `Views/MockAPIView.swift:351-417`：响应体/请求体编辑器传 `focusToken: mockCase.id`，新增或切换 case 后自动聚焦到响应体末尾。
   - 配合 Phase 3 的防抖 Binding / 大文本模式 / 补全门槛；粘贴 100KB base64 不再触发整页重算与正则高亮。
   - 编辑器顶部加轻量状态：`N 字符 · JSON`（可选，便于确认大文本已加载）。
2. **Tab 滑到 Collection 面板后面**
   - `Views/RootView.swift`：用 `HStack(spacing:0)` 左右分栏替换 `NavigationSplitView`：侧栏固定 240–380（可拖拽，`@AppStorage` 记忆），1px 分隔线，detail `.clipped()`。
   - `TabBarView` 去掉 `leadingInset` 依赖；`ScrollViewReader` 保留居中滚动。
   - 顶栏窗口控制浮层仍覆盖侧栏左上角。
3. **移除底部 Mock API 按钮，底部加入环境变量入口**
   - `Views/SidebarView.swift:420-438`：删除 `server.rack` 按钮；新增 `globe` 按钮（带当前环境颜色圆点），点击打开环境工作区。
   - 顶部 `modePicker` 保留 Mock API（仍可发现）；`PostmanSwiftApp` 菜单保留 Mock API，⌘E 改为打开环境工作区。
4. **环境变量改为整块面板 + 着色**
   - `Views/EnvironmentAndSettingsViews.swift`：新增 `EnvironmentWorkspaceView`（全宽，占据 detail，不再用 sheet）：
     - 左侧环境列表：Globals + 各环境，稳定色点/左边框、变量数、Active 徽章；
     - 右侧编辑区：名称内联编辑、变量表（key 蓝色、value 绿色、禁用灰、`{{var}}` 青色）、添加/删除、Set Active、导入导出；
     - 颜色由 `EnvironmentPalette.color(for: id/name)` 稳定映射（8 色），Globals 固定紫色。
   - `RootView` 移除环境 sheet，改为 `store.workspace = .environments`；侧栏环境菜单“Manage Environments…”改为打开该面板。
   - 新增 `@Published var workspace: WorkspaceKind`（requests/mock/environments）；打开请求/历史时自动回 requests；`sidebarMode == .mock` 时显示 Mock 工作区。
5. **代码按钮慢且关不掉**
   - `Views/RunnerView.swift:200-233`：`@State` 缓存按语言生成的片段，`.task(id: language)` 后台生成，生成中显示 ProgressView；`Close` 显式 `store.closeCodeSnippet()` + `dismiss()`；`.onDisappear` 清理状态。
   - `RootView` 用 `.sheet(item:)` 绑定 `codeSnippetTabID`，避免 `RequestTab` 发布导致 ResponseView 重算。
   - 打开时立即出弹窗（不等待片段生成）。
6. **窗口左上角双击铺满**
   - `Views/Components.swift:200-206`：`mouseDown` 中 `event.clickCount == 2` → `window?.zoom(nil)`；否则 `performDrag`。
   - 保留自绘红灯/黄灯/绿灯；绿灯仍 `zoom(nil)`。

### Phase 5：测试、打包、端到端验证

- 单元测试（`Tests/PostmanSwiftTests/MockAndCompletionTests.swift` 扩展，必要时新增 `DocumentTreeTests.swift`）：
  - 分类器：PDF/IMG/JSON/XML/URL/普通文本，含 data URI。
  - 嵌套展开：JSON-in-JSON、XML-in-JSON、JSON-in-XML、CDATA/实体、嵌套 PDF/IMG 在原路径出现。
  - XML 树：属性、文本、子节点顺序、非法 XML 回退。
  - 序列化：pretty 保留 key 顺序/数字字面量、base64 占位、无 `JSONSerialization` 依赖。
  - 内存预算：纯函数 eviction 选择；文本准备缓存 key 稳定性；`utf8.count` 路径不触发字符计数。
  - 旧测试全绿（含 `PDFExtractor`、`JSONFormatting` 兼容契约）。
- 构建：`swift build -c release`、`swift test`、`Scripts/build_app.sh release`。
- 基线/对比：同一 harness 对 baseline 与新版本各跑一遍，输出指标表。
- 隔离实例：`POSTMANSWIFT_DATA_DIR=/tmp/pn-verify` 启动，避免碰用户数据。
- UI 自验：
  - 自截图检查：侧栏/Tab 不穿透、环境面板全宽且着色、Mock 响应体有光标、代码弹窗可关闭、双击铺满。
  - 交互压测：5 个用例 Preview 展开嵌套与媒体；Raw/Pretty 滚动；标签间快速切换 20 轮；Mock 粘贴 100KB 后继续输入；代码弹窗 10 次开关。
  - 内存/CPU：`task_info` 采样 + `ps -o rss` 复核；`sample` 留档；检查 `~/Library/Logs/DiagnosticReports` 无新 crash/hang。
- 清理：删除 `PerfQAHarness.swift` 与 AppDelegate 钩子；重建正式 release；清理 `/tmp` 验证数据（保留结果日志摘要）。
- 最终报告：写入 `.agent/<yyyyMMdd-HHmm>-perf-report.md`（与方案同前缀），并在回复中给出改动文件、前后指标、剩余风险（若有）。
- 方案与报告均存放在项目 `.agent/`，不提交到用户数据目录，也不覆盖用户已有的 `.agent` 内容。

## 关键文件清单

- Core：`Sources/PostmanSwift/Core/JSONTree.swift`、`Core/PDFExtractor.swift`、`Utilities/URLUtilities.swift`
- Store：`Sources/PostmanSwift/Store/AppStore.swift`、`Store/RequestTab.swift`
- Views：`Views/JSONTreeView.swift`、`Views/CodeText.swift`、`Views/ResponseView.swift`、`Views/RootView.swift`、`Views/WorkspaceView.swift`、`Views/SidebarView.swift`、`Views/MockAPIView.swift`、`Views/EnvironmentAndSettingsViews.swift`、`Views/RunnerView.swift`、`Views/Components.swift`
- App：`App/PostmanSwiftApp.swift`（⌘E、窗口行为）
- 测试：`Tests/PostmanSwiftTests/MockAndCompletionTests.swift`（+ 新测试文件）
- 临时（最终删除）：`Sources/PostmanSwift/App/PerfQAHarness.swift`

## 决策与风险

- **不做**完整 WebView/Electron 式虚拟化编辑器；用 TextKit 2 + 视口布局 + 软换行缓存，保持原生与低内存。
- **不做**响应落盘重写；保留 `result.body`，只按预算释放 text/pretty/tree，保证切回可恢复。
- XML 属性顺序以解析器稳定输出为准（按名称排序），内容与层级不受影响。
- macOS 26 Liquid Glass 下改用显式左右分栏，视觉保持玻璃侧栏但彻底避免穿透。
- 若 TextKit 2 在极端 1.7MB 单行上仍卡，Fallback：Raw 默认显示前 2MB 并以“显示全部”按钮延后加载（仍可查看，不冻结）。
- 所有性能结论以 Release + harness 实测为准；代码审查发现均视为 hypothesis，直到指标确认。
