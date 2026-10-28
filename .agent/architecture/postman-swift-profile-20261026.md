# PostmanSwift — SwiftUI + Time Profiler 剖析报告

- 日期：2026-10-26
- 目标：找出当前 UI/响应渲染的主要 CPU 热点，验证 10-26 的树/媒体修复，并给出下一步优化顺序
- 构建：Release（SwiftPM `swift build -c release`）
- 负载：临时自驱动 ProfilingHarness（已删除）：3 个真实响应标签（`resp_1` 1.7MB、`base64_json`、`json_in_json`），全屏 1728×1084，15 秒内切换 Preview/Raw/Pretty、滚动树、编辑草稿（触发 session 保存）
- 采集：`xcrun xctrace record --instrument 'SwiftUI' --instrument 'Time Profiler' --attach <pid> --time-limit 20s`
- Trace：`/tmp/pn-profile.trace`
- 导出 XML：`/tmp/pn-prof-time-profile.xml`（7,273 rows，11MB）
- 原始采集日志：`/tmp/pn-profile-record.log`、`/tmp/pn-profile.log`

## 1. 采集限制

- SwiftUI instrument 在 **attach 和 `--launch` 两种方式**下都报告 `Trace file had no SwiftUI data`，`swiftui-updates/changes/update-groups/causes` 表均为 0 行；本机 Xcode 26 / macOS 26.5.2 下该 SwiftUI 模板未产出可用数据。
- 因此本报告以 Time Profiler 的调用栈为主；SwiftUI 层面的“哪个 View body 更新”无法从本次 trace 直接确认。
- `--launch` 方式下进程未创建窗口（日志 `FATAL no window`），只有 attach 模式可用。

## 2. 总体

| 指标 | 值 |
|---|---:|
| 采样总时长 | 7,273 ms |
| 主线程 | 5,981 ms（82.2%） |
| 非主线程合计 | 1,292 ms |
| Workload 实际迭代 | 44 次 |
| 采集窗口 | 20s（app 在结束后自退出） |

主线程高占比是预期的：SwiftUI 布局 + Core Animation 提交 + TextKit 布局都在主线程。关键不是总量，而是热点分布。

## 3. 主线程 inclusive 热点（按占用排序）

| 栈节点 | 时间 | 占主线程 |
|---|---:|---:|
| `CA::Transaction::commit()` 及其下游 | 2,905 ms | 48.6% |
| `GraphHost.flushTransactions()` | 2,347 ms | 39.2% |
| `ViewGraphRootValueUpdater.updateGraph` / SwiftUI graph update | 1,896–1,923 ms | 31.7% |
| `LayoutEngineBox/ViewLayoutEngine.sizeThatFits` | 1,071 ms | 17.9% |
| `GeometryReaderLayout.placeSubviews` | 853 ms | 14.3% |
| `NSTrackingArea / NSCursor / AXFMouseCursorGenerator` | 1,261 ms | 21.1% |
| `NSTextView` 相关（含 `NSLayoutManager`） | ~2,802 ms | ~46.8%（含重叠） |
| `NSLayoutManager` 相关 | 2,332 ms | ~39%（含重叠） |
| PDF/Image 相关（`PDF`） | 1,199 ms | 20.0%（含重叠） |
| `AppStore` | 39 ms | 0.7% |
| `JSONEncoder` / `persistSession` | 14 ms / 3 ms | <0.3% |
| `JSONTree` / `LazyStack` / `LazyLayout` | 16 / 18 / 40 ms | <0.7% |

> 百分比为 inclusive，多个栈节点会重叠，不应相加。

## 4. 主线程 self 热点（叶子）

| 叶子函数 | 时间 | 占主线程 |
|---|---:|---:|
| `objc_msgSend` | 212 ms | 3.5% |
| `<deduplicated_symbol>` | 174 ms | 2.9% |
| `A8_image_mark_rgb32`（图像绘制/PDF/图片） | 167 ms | 2.8% |
| `_platform_memset` | 134 ms | 2.2% |
| `AG::Graph::propagate_dirty` | 131 ms | 2.2% |
| `AG::Graph::UpdateStack::update` | 112 ms | 1.9% |
| `conv4_8_ABCD` / `conv4_8_A`（vImage） | 132 ms | 2.2% |
| `_platform_memmove` | 65 ms | 1.1% |
| Swift metadata cache / retain-release | 60–64 ms | ~2.0% |
| `__open` | 43 ms | 0.7% |

## 5. 归因与结论

### 5.1 树/媒体卡片的修复有效
- `LazyStack` / `LazyLayout` / `JSONTree` 合计 <60ms，主线程占比 <1%。
- 说明 10-26 的修复（小树 VStack、媒体卡片折叠、固定尺寸、加载占位同高）已经移除了之前 100% CPU 的 `LazyStack.measureEstimates` 循环。
- 本次负载包含 1.7MB PDF、5KB PDF/PNG、90 行嵌套 JSON，且进行了 Raw/Pretty 切换和滚动。

### 5.2 主要成本是 SwiftUI 布局/提交，而不是解析
- `CA::Transaction::commit` 48.6% + `GraphHost.flushTransactions` 39.2%：UI 更新事务与渲染提交占大头。
- `sizeThatFits` 17.9% + `GeometryReaderLayout` 14.3%：`RequestWorkspaceView` 的 GeometryReader（上下分栏）+ 外层 VStack/ScrollView 的尺寸计算是明确热点。
- 与 H1（AppStore 单一 ObservableObject、广播式失效）一致：任意状态变化让较大子树重新测量；建议拆分状态/窄化观察后再测一次，预期能直接压低这两项。

### 5.3 NSTextView/TextKit 是第二热点
- `NSTextView` 相关 inclusive ~2.8s、`NSLayoutManager` ~2.3s；`-[NSTextView setFrameSize:]` 227ms、`_ensureLayoutComplete` ~388ms。
- 当前 `RawCodeTextView.updateNSView` **每次更新都调用 `resize()` 并设置 `textView.frame`**，即使尺寸没变。Raw/Pretty 切换、标签切换、搜索/滚动都会触发 update，容易重复触发布局。
- 建议：在 `resize` 中比较目标 size，只有变化 >0.5pt 才设置 frame；把 `RawCodeTextView` 按 `(tab.id, mode)` 稳定 identity，避免无关更新；大文本只在准备完成/宽度变化时做一次尺寸计算。

### 5.4 光标/跟踪区域占比异常（需用真实触控板复测）
- `NSTrackingAreaAKManager` + `NSCursor` + `AXFMouseCursorGenerator` 约 21% 主线程，`createImageForScale` 15.5%。
- 本次负载通过 `NSScrollView.scroll(to:)` 程序化滚动，AppKit 会不断重算 tracking area/cursor 图像；真实触控板滚动通常低得多。
- 这是一个**测量偏差**，不应直接据此改产品代码；建议用真实触控板/鼠标滚动复测一次，若仍 >10% 再排查窗口 tracking/cursor 配置。

### 5.5 PDF/图片渲染成本符合预期
- PDF 相关 inclusive 1.2s，主要来自首次页缩略图渲染/图像绘制（`A8_image_mark_rgb32`、`vImage`）；卡片默认折叠后只在展开时发生。
- 当前 PDF/Image 缓存有 32MB `totalCostLimit`，继续保留；不要为了省 CPU 把缩略图改回大图/PDFView。

### 5.6 本次负载没有压到 H2/H3
- `JSONEncoder` 14ms、`persistSession` 3ms、`AppStore` 39ms：因为 harness 的 draft 很小，且只保留 3 个响应。
- H2（session 全量编码）和 H3（body 常驻）仍是结构风险；需要单独用“200KB 草稿 + 8 个 1.7MB 标签”的负载复测，不能以本次低占比否定它们。

## 6. 建议动作（按优先级）

1. **修 `RawCodeTextView.resize` 的重复 frame 设置**（低风险、直接针对 2.8s NSTextView 热点）：尺寸未变不赋值；只在文本/宽度/换行变化时更新。
2. **拆分 AppStore / 窄化观察**（H1）：先做 `TabStore` 或把 `showCode/UI flags` 移出；`ResponseView` 已按 tab.id 重建，继续给高频子树加 `.equatable()`。
3. **减少 `GeometryReader` 重排**：`RequestWorkspaceView` 的上下分栏可改用固定 `VStack` + 保存高度，拖动时只更新分栏高度；或把分栏容器换成 `NSSplitView`，避免每次状态更新都重算 GeometryReader。
4. **H2 单独压测**：构造 200KB draft + 8 个 1.7MB 标签，确认 session 主线程编码和 body 常驻的真实成本；再决定后台 session 编码/body LRU。
5. **真实触控板复测光标热点**：排除程序化滚动造成的 tracking/cursor 噪声。

## 7. 复现命令

```bash
# 1) 启动带 ProfilingHarness 的 QA bundle（本次临时构建，已删除）
# 2) 附加录制
xcrun xctrace record \
  --instrument 'SwiftUI' \
  --instrument 'Time Profiler' \
  --attach <pid> --time-limit 20s \
  --output /tmp/pn-profile.trace

# 3) 导出 Time Profiler 表
xcrun xctrace export --input /tmp/pn-profile.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  > /tmp/pn-prof-time-profile.xml
```

> 复测时请保持同一负载（3 个 media 响应、44 次切换/滚动）才能对比；SwiftUI instrument 在本机仍可能为空，需用 Time Profiler 或 Xcode GUI 再确认。
