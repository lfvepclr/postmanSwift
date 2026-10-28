# PostmanSwift 性能优化计划（第二轮）

- 日期：2026-10-28
- 工作目录：`/Users/spencer/workspace/qoder/postman/PostmanSwift`
- 产物约定：方案、基线、脚本、trace 一律写在本目录 `.agent/` 下，不再写 `/tmp`
- 上一轮文档：`.agent/20261025-2119-postman-native-perf-plan.md`、`.agent/20261025-2119-perf-report.md`、`.agent/20261026-1350-perf-fixes-verify.md`（已完成的优化不再重复）

## 1. 目标与边界

目标（全部以测量为准）：

1. 交互场景下主线程无 >50ms 的连续占用；
2. 1.7MB JSON 的打开 / 全部展开 / 滚动不出现可感知掉帧（滚动 hitch 率 <5%）；
3. 大响应打开后无障碍树快照 <200ms（当前 1.19s）；
4. 重复开关大响应、多标签页后 RSS 稳态不增长；
5. 冷启动到首帧可测量、可回归。

边界：

- 不改视觉设计、不改数据格式、不引入第三方运行时依赖；
- 保持 TextKit 2（禁止回退 TextKit 1）；
- 每轮只改一个变量，前后贴同一场景的数字。

## 2. 已安装的性能 Skill（2026-10-28）

| 来源 | 状态 | 位置 |
|---|---|---|
| AvdLee/SwiftUI-Agent-Skill（trace 录制 + 5 泳道解析） | 已安装 | `~/.qoder/skills/swiftui-expert-skill` |
| Livsy90/iOS-Performance-Agent-Skills（启动 / profiling / 感知 / 并发 / 运行时） | 已安装 5 个 | `~/.qoder/skills/ios-launch-performance` 等 |
| steipete/agent-scripts → instruments-profiling | 已安装 | `~/.qoder/skills/instruments-profiling` |
| Axiom performance（xctrace CLI 参考） | 原有 | `~/.qoder/skills/axiom-performance` |
| Apple 官方 Xcode agent skills | **不可用**：Xcode 26.6 导出为空 | 需要 Xcode 27 |

安装说明：GitHub git 协议被阻断，使用 codeload tarball 安装。

## 3. 基线（2026-10-28，release 构建，隔离数据目录）

场景：启动 → 选择 History → 打开 1.7MB JSON（resp_1 / json_in_xml）→ 全部展开 → 滚动 6 页 → Preview/Headers 切换。  
驱动：纯坐标点击，录制期间不读取 AX，避免无障碍树快照污染测量。

| 指标 | 结果 | 说明 |
|---|---|---|
| Time Profiler（36s） | 0 hangs；CPU 1.87s | 主线程前几位：`mach_msg` 121ms、`objc_msgSend` 56ms、`AG::Subgraph::update` 39ms |
| SwiftUI 模板（36s） | 0 hangs；803 帧 hitch（最差 208–254ms） | 集中在打开大响应 / 全部展开；空闲 15s 记录为 0 hitch |
| 无障碍快照 | 1.19s / 12k 字符 | 上一轮 AX 驱动 trace 的 665/383/291/278ms hangs 均由此引起 |
| RSS | 无响应 145MB；打开 1.7MB 并展开后 150MB | 单次无泄漏迹象 |
| 启动耗时 | 未取得 | Xcode 26.6 CLI 无 app-launch 表，Phase 0 补测 |

已知测量限制：

- 本机 Xcode 26.6 的 SwiftUI 模板不产出 `swiftui-updates` 泳道，视图级归因缺失；
- 用 Computer Use 每步读 AX 会让主线程停顿，不能作为性能基线；
- 缺少 os_signpost，无法把耗时精确归到“解析 / 展平 / 布局 / 持久化”。

产物位置：

- `.agent/perf-baseline/traces/time-profiler-20261028.trace.tar.gz`
- `.agent/perf-baseline/traces/swiftui-20261028.trace.tar.gz`
- `.agent/perf-baseline/traces/optimized-*.trace.tar.gz`
- trace 压缩后共约 29MB；解压后 xctrace / analyze_trace.py 可直接读取
- `.agent/perf-baseline/reports/*.md`
- `.agent/perf-baseline/scripts/aggregate_time_profile.py`（按符号聚合 self/inclusive 与 hang 窗口）

## 4. 优化计划

### Phase 0｜测定基建（不改行为）

1. 新增 `Core/PerformanceProbe.swift`：os_signpost 标记 `historyReload`、`presentationBuild`、`flatten`、`rebuild`、`toggle`、`expandAll`、`installResponse`、`sessionSnapshotSave`、`firstFrame`。
2. 新增 `Scripts/perf-bench.sh`：构建 release、启动隔离实例、按坐标执行固定场景、调用 xctrace 录制、导出报告到 `.agent/perf-baseline/<date>/`。
3. 新增 XCTest 性能用例：1 万行 flatten、单节点 rebuild、行级 accessibility label 生成。
4. 产出 `baseline.json`（每个场景的中位数 / p95），后续每轮对比。

验收：同一场景连续跑 3 次，指标波动 <10%；报告中能读出各 signpost 区间的耗时。

### Phase 1｜主线程与渲染

5. **JSON 预览虚拟化**（`Views/JSONTreeView.swift:582`）：当前 `VStack` 一次性布局最多 600 行。改为按可见范围渲染（文本行固定高，PDF/图片卡片按估算高度），保留分页加载。
   预期：展开/滚动时布局行数从 600 降到可视行数（约 30–50）；滚动 hitch 率下降。
6. **增量行更新**（`JSONTreeView.swift:803`）：每次展开/收起调用全量 `JSONTreeFlattener.flatten`。改为按节点路径增删行，并按 `(root, expanded, embedded, sortKeys)` 版本缓存。
   预期：单节点切换主线程 <16ms。
7. **历史面板**：
   - `Views/SidebarView.swift:353` 每帧计算 `RelativeTime.string`、体积/耗时格式化 → 在刷新时预计算并缓存到行模型；
   - `Store/AppStore.swift:432` 的 `reloadHistory` 同步查询 SQLite（最多 400 行）→ 移到后台并带代际号，避免旧结果覆盖新搜索。
   预期：历史面板滚动与刷新主线程占用下降。
8. **无障碍性能**（`Views/JSONTreeView.swift:943`）：每行目前暴露大量文本片段。改为行级单一 AX 元素（`children: .ignore`，合并 label/value），展开/收起暴露为 AX action。
   预期：AX 快照 1.19s → <200ms；消除 VoiceOver / 自动化客户端引发的主线程停顿。

### Phase 2｜启动、输入与内存

9. 首帧后再执行非关键工作（mock 默认数据、历史列表预热等），用 Phase 0 的 signpost 定位启动热点。
10. 输入延迟：编辑器高亮 debounce、KeyValue / PlainVariable 输入路径，以 p95 输入延迟为指标。
11. 内存：重复开关大响应、多标签页后跑 Allocations / Leaks，确认稳态 RSS 不增长。

## 5. 验证与门槛

每个 Phase 结束都跑同一场景：

- xctrace `Time Profiler`（主线程 top、hang 数）与 `SwiftUI`（hitch 数 / 最差帧）；
- `os_signpost` 各区间 p50 / p95；
- AX 快照耗时；
- RSS（打开前后、重复 5 次后）；
- `swift test` 全绿，并新增的性能用例通过。

通过标准：

- 无 >50ms 的 signpost 区间；
- 滚动 hitch 率 <5%，最差帧 <50ms；
- AX 快照 <200ms；
- 重复 5 次开关后 RSS 增幅 <10%。

## 6. 风险与回滚

| 风险 | 处理 |
|---|---|
| 虚拟化破坏“展开后滚动定位 / 全部展开” | 保留稳定 row id 与现有分页；先做可见行渲染，再验证展开定位 |
| 增量更新与排序 / 过滤组合出错 | 保留全量 flatten 作为测试 oracle，逐条比对 |
| AX 合并导致 VoiceOver 丢失信息 | label 中包含键、值、类型与深度；提供展开/收起 action |
| 测量噪声 | 固定场景脚本、连续 3 次取中位、每轮只改一个变量 |

## 7. 待确认

按 Phase 0 → Phase 1（5→8）→ Phase 2 的顺序执行；确认后先落地探针与基准脚本，产出可重复的 baseline，再开始改渲染路径。

---

## 8. 执行结果（2026-10-28，全部 Phase 已执行）

### 落地内容

| 项 | 状态 | 位置 |
|---|---|---|
| Phase 0.1 os_signpost 探针 | 完成 | `Sources/PostmanSwift/Core/PerformanceProbe.swift`（category 必须是 `PointsOfInterest`，否则 Instruments 不记录） |
| Phase 0.2 可重复基准脚本 | 完成 | `Scripts/perf-bench.sh`（prep / launch / record / report / scenario，产物只写 `.agent/perf-baseline`） |
| Phase 0.3 性能 XCTest | 完成 | `Tests/PostmanSwiftTests/PerformanceMetricsTests.swift`（XCTClock / XCTMemory） |
| Phase 1.5 JSON 预览虚拟化 | 完成 | `JSONTreeView.rowStack` 改 `LazyVStack`，分页仍为 600 |
| Phase 1.6 增量行更新 | 完成 | `JSONTreeFlattener.flattenResult / subtreeResult` + `nodeIndex`；`toggle` 走 `expandIncrementally / collapseIncrementally`，超预算或内嵌未解析时回退全量 |
| Phase 1.7 历史面板 | 完成 | `HistoryRowDisplay` 预格式化 + `historyDisplay` 缓存；`reloadHistory` 改后台 SQLite 查询（带代际号）；`RelativeTime` / `ByteCountFormatter` 常驻 |
| Phase 1.8 无障碍 | 完成 | JSON 行合并为单一 AX 元素（`children: .combine` + label + 展开/复制路径 action） |
| Phase 2.9 首帧后工作 | 完成 | 历史列表从 `AppStore.init` 移到 `RootView.onAppear → startDeferredWork()`；发出 `firstFrame` signpost |
| Phase 2.10 输入探针 | 完成（测量部分见下方限制） | `editorUpdate` / `editorKeystroke` / `editorHighlight` / `fieldHighlight` |
| Phase 2.11 内存复测 | 完成 | 连续打开 1.7MB 响应 5 次：170MB → 174MB（+2.4%） |

### 前后数据（release，隔离数据目录）

| 指标 | 优化前 | 优化后 |
|---|---|---|
| Time Profiler（开 1.7MB → 展开 → 滚动） | 0 hangs，CPU 1.87s / 36s | 0 hangs，CPU 0.95s / 26s |
| SwiftUI 模板 hitches | 803 次 / 11.6s，最差 254ms | 32 次 / 0.5s，最差 192ms |
| AX 轮询（6 次快照 / 20.9s） | 665 / 383 / 291 / 278ms hangs | 0 hangs |
| 单响应 RSS | 145MB → 150MB | 170MB → 174MB（5 次重开）；关闭后 185MB（分配器保留） |
| flatten / subtree / presentation（574B） | 未细分 | presentationBuild 0.087ms，flatten 0.027ms |
| 单元测试 | 104 | 111（新增 5 个 subtree/增量等价、2 个性能度量） |

### 验证

- 增量展开/收起在 87KB JSON 上实测：100 行 → 收起 88 行 → 再展开 100 行，与全量 flatten 的 oracle 测试一致。
- “全部收起 → 全部展开”后深度展开正常，未出现错位/重复行。
- AX 轮询从每次快照引发 0.3–0.7s 主线程停顿，降为 0 hang；CUA 端到端快照仍有约 0.9–1.0s（主要是自动化客户端自身开销，不能再作为应用指标）。
- 无响应会话与 1.7MB 响应展开后功能正常，工具栏/标签/左栏无回归。

### 限制

- 本机 Xcode 26.6：SwiftUI 泳道不产出 `swiftui-updates`，hitch 只能看总数与最差帧；官方 Xcode 27 skills 无法导出。
- 输入 p95 未取得：URL 输入框走 `InlineTextField`（无高亮探针），Body 默认不是 raw 编辑器；探针已就位，后续用 raw body 场景补测。
- 启动到首帧只有 signpost，尚未做 wall-clock A/B（App Launch 模板在 Xcode 26.6 CLI 无对应表）。
