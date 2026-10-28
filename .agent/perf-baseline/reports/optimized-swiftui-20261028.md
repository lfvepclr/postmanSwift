# Instruments Trace Analysis
Trace: `.agent/perf-baseline/traces/optimized-swiftui-20261028.trace`  •  16.0 (17F113)  •  SwiftUI
Recording duration: 25.78s

## Time Profiler — 9,608 samples, 961ms CPU time
Processes: PostmanSwift

Top offenders:
1. `mach_msg2_trap` — 8.1% (78ms, 780 samples, main)
2. `<deduplicated_symbol>` — 2.7% (26ms, 262 samples, main)
3. `objc_msgSend` — 2.1% (20ms, 198 samples, main)
4. `__mac_syscall` — 2.0% (20ms, 196 samples, main)
5. `AG::Graph::propagate_dirty(AG::AttributeID)` — 1.8% (17ms, 169 samples, main)
6. `AG::Graph::UpdateStack::update()` — 1.6% (15ms, 153 samples, main)
7. `DYLD-STUB$$protocol witness for OptionSet.init(rawValue:) in conformance DisplayList.Prop…` — 1.6% (15ms, 152 samples, main)
8. `_platform_memmove` — 1.4% (13ms, 132 samples, main)

## Hangs — 0 hangs, 0ms total, worst 0ms
Severity: <250ms=0, 250ms–1s=0, >1s=0


## Animation Hitches — 32 hitches, 500ms total, worst 192ms
By process: PostmanSwift=32

Apple attribution: Potentially expensive app update(s)=10
System vs app: system=0, app=32

1. 192ms at 4332.11ms (PostmanSwift) — Potentially expensive app update(s)
2. 25ms at 8248.76ms (PostmanSwift) — Potentially expensive app update(s)
3. 17ms at 2307.11ms (PostmanSwift) — Potentially expensive app update(s)
4. 17ms at 13002.92ms (PostmanSwift)
5. 17ms at 20502.90ms (PostmanSwift) — Potentially expensive app update(s)
6. 12ms at 9815.43ms (PostmanSwift) — Potentially expensive app update(s)
7. 12ms at 11640.42ms (PostmanSwift)
8. 8ms at 13269.58ms (PostmanSwift) — Potentially expensive app update(s)

## SwiftUI — 0 updates across 0 views, 0ms total


## SwiftUI Cause Graph — 0 edges, 0 sources → 0 destinations


## Correlations

- **hitches** at 4332.11ms (192ms)
  - Main thread: 0 running samples (0% coverage — blocked)
    · no main-thread samples in window
- **hitches** at 8248.76ms (25ms)
  - Main thread: 178 running samples (100% coverage — mostly running)
    · `mach_msg2_trap` 11% (20 samples)
    · `objc_msgSend` 3% (5 samples)
    · `__bsdthread_ctl` 3% (5 samples)
- **hitches** at 2307.11ms (17ms)
  - Main thread: 0 running samples (0% coverage — blocked)
    · no main-thread samples in window
- **hitches** at 13002.92ms (17ms)
  - Main thread: 94 running samples (100% coverage — mostly running)
    · `mach_msg2_trap` 13% (12 samples)
    · `__kdebug_trace64` 7% (7 samples)
    · `__mac_syscall` 4% (4 samples)
- **hitches** at 20502.90ms (17ms)
  - Main thread: 0 running samples (0% coverage — blocked)
    · no main-thread samples in window
