# Instruments Trace Analysis
Trace: `.agent/perf-baseline/traces/optimized-interaction-clean-20261028.trace`  •  16.0 (17F113)  •  Time Profiler
Recording duration: 25.83s

## Time Profiler — 950 samples, 950ms CPU time
Processes: PostmanSwift

Top offenders:
1. `mach_msg2_trap` — 8.5% (81ms, 81 samples, main)
2. `<deduplicated_symbol>` — 3.5% (33ms, 33 samples, main)
3. `start_wqthread` — 2.1% (20ms, 20 samples, tid 0x1b3d3b5)
4. `objc_msgSend` — 1.9% (18ms, 18 samples, main)
5. `DYLD-STUB$$protocol witness for OptionSet.init(rawValue:) in conformance DisplayList.Prop…` — 1.8% (17ms, 17 samples, main)
6. `__mac_syscall` — 1.7% (16ms, 16 samples, main)
7. `_kernelrpc_mach_port_deallocate_trap` — 1.4% (13ms, 13 samples, main)
8. `AG::Graph::propagate_dirty(AG::AttributeID)` — 1.4% (13ms, 13 samples, main)
9. `swift_release` — 1.4% (13ms, 13 samples, main)
10. `swift_bridgeObjectRetain` — 1.3% (12ms, 12 samples, main)
11. `AG::Subgraph::update(unsigned int)` — 1.3% (12ms, 12 samples, main)
12. `__kdebug_trace64` — 1.1% (10ms, 10 samples, main)

## Hangs — 0 hangs, 0ms total, worst 0ms
Severity: <250ms=0, 250ms–1s=0, >1s=0


## Animation Hitches — skipped — Animation hitches not present in trace.

## SwiftUI — skipped — SwiftUI lane not in trace (Xcode 26+ SwiftUI template required).

## SwiftUI Cause Graph — skipped — SwiftUI causes data not present (requires SwiftUI template on a real device).
