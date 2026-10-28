# 性能基线（2026-10-28）

全部产物留在本目录；不再写入 `/tmp`。

## 内容

- `traces/time-profiler-20261028.trace.tar.gz`：优化前，36s，打开 1.7MB JSON → 全部展开 → 滚动，纯坐标驱动（录制期间不读 AX）。
- `traces/swiftui-20261028.trace.tar.gz`：优化前，36s，同场景，SwiftUI 模板（含 Animation Hitches）。
- `reports/time-profiler-20261028.md`：AvdLee `analyze_trace.py` 输出（Time Profiler 摘要 + hangs）。
- `reports/swiftui-20261028.md`：SwiftUI 模板输出（hitches 摘要）。
- `reports/swiftui-idle-20261028.md`：15s 空闲记录（0 hang / 0 hitch），trace 已删除以节省空间。
- `scripts/aggregate_time_profile.py`：按符号聚合 self / inclusive，并按 hang 时间窗打印 app 帧占比。

## 复现步骤

```bash
# 1) 准备隔离实例（不污染日常数据）
cp -R dist/PostmanSwift.app .agent/perf-baseline/tmp/PNPerf.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.postmanswift.perfqa" .agent/perf-baseline/tmp/PNPerf.app/Contents/Info.plist
# 数据目录：复制 library.json / history.sqlite / history-bodies 到 .agent/perf-baseline/tmp/data

# 2) 启动并录制（录制期间不要读取无障碍树）
osascript -e 'tell application "PNPerf" to activate'
xcrun xctrace record --template 'Time Profiler' --attach <pid> --time-limit 35s \
  --output .agent/perf-baseline/traces/time-profiler-$(date +%Y%m%d).trace --no-prompt

# 3) 分析
python3 ~/.qoder/skills/swiftui-expert-skill/scripts/analyze_trace.py \
  --trace .agent/perf-baseline/traces/time-profiler-20261028.trace \
  --top 15 --output .agent/perf-baseline/reports/time-profiler-20261028 --markdown-only

# 4) 按符号聚合
xcrun xctrace export --input .agent/perf-baseline/traces/time-profiler-20261028.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  > .agent/perf-baseline/tmp/time-profile.xml
python3 .agent/perf-baseline/scripts/aggregate_time_profile.py .agent/perf-baseline/tmp/time-profile.xml
```

## 关键结果（release，隔离数据目录）

| 指标 | 优化前 | 优化后 |
|---|---|---|
| Time Profiler | 0 hangs，CPU 1.87s / 36s | 0 hangs，CPU 0.95s / 26s |
| SwiftUI hitches | 803 次 / 11.6s，最差 254ms | 32 次 / 0.5s，最差 192ms |
| AX 轮询（6 次 / 20.9s） | 665 / 383 / 291 / 278ms hangs | 0 hangs |
| 空闲（15s） | 0 hang / 0 hitch | 未复测（行为不变） |
| RSS | 145MB → 150MB | 170MB → 174MB（5 次重开）；关闭后 185MB（分配器保留） |
| flatten / presentation | 未细分 | 0.027ms / 0.087ms（574B 样本） |

机器可读版本：`.agent/perf-baseline/baseline-20261028.json`。

## 优化后新增 trace（全部为 .tar.gz，解压后是 .trace 目录）

- `traces/optimized-interaction-clean-20261028.trace.tar.gz`：坐标驱动，无 AX 读取。
- `traces/optimized-swiftui-20261028.trace.tar.gz`：SwiftUI 模板，hitches 对比。
- `traces/optimized-axpoll-20261028.trace.tar.gz`：录制中每 2s 读一次 AX，验证 hang 是否消失。
- 报告在 `reports/optimized-*.md`。

解压示例：

```bash
cd .agent/perf-baseline/traces
tar xzf optimized-swiftui-20261028.trace.tar.gz
```


## 基准脚本

```bash
Scripts/perf-bench.sh launch                  # 构建 + 隔离实例，打印 pid
Scripts/perf-bench.sh record <pid> 30 "Time Profiler"
Scripts/perf-bench.sh report <trace> <name>   # analyzer + 符号聚合
Scripts/perf-bench.sh scenario                # 固定交互脚本
```

## 注意

- 用 Computer Use 每步读取 AX 会让主线程停顿（665/383/291/278ms 的 hang 均来自 AX 快照），不得混入普通基线；AX 性能单独用 axpoll trace 衡量。
- os_signpost 必须使用 `OSLog(subsystem:category: .pointsOfInterest)`，其他 category 不会被 Instruments 的 Points of Interest 表记录。
- Xcode 26.6 的 SwiftUI 模板不产出 `swiftui-updates` 泳道，视图级归因需 Xcode 27 或 os_signpost 补充。
- `aggregate_time_profile.py` 需要先按上面的 xpath 导出 XML，脚本默认读取传入路径（改版后的脚本已支持命令行参数）。
