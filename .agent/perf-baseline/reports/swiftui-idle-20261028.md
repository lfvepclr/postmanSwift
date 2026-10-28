# Instruments Trace Analysis
Trace: `/tmp/perf_idle.trace`  •  16.0 (17F113)  •  SwiftUI
Recording duration: 15.87s

## Time Profiler — 102 samples, 10ms CPU time
Processes: PostmanSwift

Top offenders:
1. `start_wqthread` — 14.7% (2ms, 15 samples, tid 0x1b073c8)
2. `mach_msg2_trap` — 9.8% (1ms, 10 samples, tid 0x1b073c7)
3. `madvise` — 4.9% (0ms, 5 samples, main)
4. `_kernelrpc_mach_port_extract_member_trap` — 3.9% (0ms, 4 samples, main)
5. `_dispatch_workloop_worker_thread` — 2.9% (0ms, 3 samples, tid 0x1b073cc)

## Hangs — 0 hangs, 0ms total, worst 0ms
Severity: <250ms=0, 250ms–1s=0, >1s=0


## Animation Hitches — 0 hitches, 0ms total, worst 0ms

System vs app: system=0, app=0


## SwiftUI — 0 updates across 0 views, 0ms total


## SwiftUI Cause Graph — 0 edges, 0 sources → 0 destinations
