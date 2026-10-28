# Instruments Trace Analysis
Trace: `.agent/perf-baseline/traces/optimized-axpoll-20261028.trace`  •  16.0 (17F113)  •  Time Profiler
Recording duration: 20.86s

## Time Profiler — 736 samples, 736ms CPU time
Processes: PostmanSwift

Top offenders:
1. `mach_msg2_trap` — 10.5% (77ms, 77 samples, tid 0x1b3aebf)
2. `<deduplicated_symbol>` — 2.7% (20ms, 20 samples, main)
3. `objc_msgSend` — 2.5% (18ms, 18 samples, main)
4. `__mac_syscall` — 2.0% (15ms, 15 samples, main)
5. `_kernelrpc_mach_port_deallocate_trap` — 1.9% (14ms, 14 samples, main)
6. `__kdebug_trace64` — 1.5% (11ms, 11 samples, main)
7. `DYLD-STUB$$protocol witness for OptionSet.init(rawValue:) in conformance DisplayList.Prop…` — 1.4% (10ms, 10 samples, main)
8. `swift_release` — 1.4% (10ms, 10 samples, main)
9. `specialized find1<A>(_:key:filter:)` — 1.2% (9ms, 9 samples, main)
10. `__bsdthread_ctl` — 1.2% (9ms, 9 samples, main)

## Hangs — 0 hangs, 0ms total, worst 0ms
Severity: <250ms=0, 250ms–1s=0, >1s=0


## Animation Hitches — skipped — Animation hitches not present in trace.

## SwiftUI — skipped — SwiftUI lane not in trace (Xcode 26+ SwiftUI template required).

## SwiftUI Cause Graph — skipped — SwiftUI causes data not present (requires SwiftUI template on a real device).
