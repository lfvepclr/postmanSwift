# Instruments Trace Analysis
Trace: `/tmp/perf_time3.trace`  •  16.0 (17F113)  •  Time Profiler
Recording duration: 35.95s

## Time Profiler — 1,869 samples, 1869ms CPU time
Processes: PostmanSwift

Top offenders:
1. `mach_msg2_trap` — 6.5% (121ms, 121 samples, main)
2. `objc_msgSend` — 3.0% (56ms, 56 samples, main)
3. `<deduplicated_symbol>` — 2.9% (54ms, 54 samples, main)
4. `__mac_syscall` — 2.2% (41ms, 41 samples, main)
5. `AG::Subgraph::update(unsigned int)` — 2.1% (39ms, 39 samples, main)
6. `swift_retain` — 1.7% (32ms, 32 samples, main)
7. `__kdebug_trace64` — 1.7% (31ms, 31 samples, main)
8. `_platform_memmove` — 1.5% (28ms, 28 samples, main)
9. `DYLD-STUB$$protocol witness for OptionSet.init(rawValue:) in conformance DisplayList.Prop…` — 1.3% (25ms, 25 samples, main)
10. `specialized find1<A>(_:key:filter:)` — 1.1% (21ms, 21 samples, main)
11. `___chkstk_darwin` — 1.1% (20ms, 20 samples, main)
12. `conv4_8_A` — 1.0% (19ms, 19 samples, tid 0x1b054d4)
13. `bool objc::DenseMapBase<objc::DenseMap<DisguisedPtr<objc_object>, objc::DenseMap<void con…` — 1.0% (18ms, 18 samples, main)
14. `__bsdthread_ctl` — 0.9% (17ms, 17 samples, main)
15. `_xzm_xzone_malloc_tiny` — 0.9% (16ms, 16 samples, main)

## Hangs — 0 hangs, 0ms total, worst 0ms
Severity: <250ms=0, 250ms–1s=0, >1s=0


## Animation Hitches — skipped — Animation hitches not present in trace.

## SwiftUI — skipped — SwiftUI lane not in trace (Xcode 26+ SwiftUI template required).

## SwiftUI Cause Graph — skipped — SwiftUI causes data not present (requires SwiftUI template on a real device).
