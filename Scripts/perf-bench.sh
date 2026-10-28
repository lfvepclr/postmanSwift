#!/bin/bash
# Repeatable performance runs. Everything is written under .agent/perf-baseline.
#
# Usage:
#   Scripts/perf-bench.sh prep                  # release build + isolated app/data under .agent/perf-baseline/tmp
#   Scripts/perf-bench.sh launch                # prep + launch isolated instance, print its pid
#   Scripts/perf-bench.sh record <pid> [secs] [template]
#   Scripts/perf-bench.sh report <trace> <name> # analyzer + symbol aggregation into .agent/perf-baseline/reports
#   Scripts/perf-bench.sh scenario              # prints the interaction script to drive while recording
#
# Rule: do not read the accessibility tree while recording. AX snapshots block the main thread
# (measured 0.6-1.2s on a large JSON) and pollute both hangs and CPU samples.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/.agent/perf-baseline"
TMP="$OUT/tmp"
APP="$TMP/PNPerf.app"
DATA="$TMP/data"
ANALYZER="$HOME/.qoder/skills/swiftui-expert-skill/scripts/analyze_trace.py"

prep() {
    mkdir -p "$OUT/traces" "$OUT/reports" "$TMP"
    APP_PATH="$APP" "$ROOT/Scripts/build_app.sh" release >/dev/null
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.postmanswift.perfqa" "$APP/Contents/Info.plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Set :CFBundleName PNPerf" "$APP/Contents/Info.plist" >/dev/null
    mkdir -p "$DATA"
    local src="$HOME/Library/Application Support/PostmanSwift"
    # Isolated copy: never point the benchmark at the daily data directory.
    cp "$src/library.json" "$DATA/" 2>/dev/null || true
    cp "$src/history.sqlite" "$DATA/" 2>/dev/null || true
    rm -rf "$DATA/history-bodies"
    cp -R "$src/history-bodies" "$DATA/" 2>/dev/null || true
    rm -rf "$DATA/session-cache"
    echo "app:  $APP"
    echo "data: $DATA"
}

launch() {
    prep
    open -n --env POSTMANSWIFT_DATA_DIR="$DATA" "$APP"
    sleep 3
    local pid
    pid="$(pgrep -f "PNPerf.app/Contents/MacOS" | head -1 || true)"
    if [[ -z "$pid" ]]; then
        echo "launch failed; run again if the first launch produced no window" >&2
        exit 1
    fi
    echo "pid: $pid"
    echo "If the window is missing, quit and re-run: Scripts/perf-bench.sh launch"
}

record() {
    local pid="${1:?pid required}"
    local seconds="${2:-35}"
    local template="${3:-Time Profiler}"
    local stamp trace
    stamp="$(date +%Y%m%d-%H%M%S)"
    trace="$OUT/traces/${stamp}-${template// /-}.trace"
    xcrun xctrace record --template "$template" --attach "$pid" \
        --time-limit "${seconds}s" --output "$trace" --no-prompt
    echo "trace: $trace"
    echo "now run: Scripts/perf-bench.sh report \"$trace\" \"${stamp}-${template// /-}\""
}

report() {
    local trace="${1:?trace required}"
    local name="${2:?name required}"
    mkdir -p "$OUT/reports"
    if [[ -f "$ANALYZER" ]]; then
        python3 "$ANALYZER" --trace "$trace" --top 15 \
            --output "$OUT/reports/$name" --markdown-only >/dev/null
        echo "report: $OUT/reports/$name.md"
    fi
    xcrun xctrace export --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
        > "$TMP/time-profile.xml" 2>/dev/null || true
    if [[ -s "$TMP/time-profile.xml" ]]; then
        python3 "$OUT/scripts/aggregate_time_profile.py" "$TMP/time-profile.xml" \
            > "$OUT/reports/$name-symbols.txt"
        echo "symbols: $OUT/reports/$name-symbols.txt"
    fi
}

scenario() {
    cat <<'TEXT'
Baseline scenario (drive from another agent/automation; no AX reads while recording):

 1. Activate the PNPerf window.
 2. Sidebar → History.
 3. Open a 1.7 MB JSON history entry (resp_1 / json_in_xml).
 4. Preview → 全部展开.
 5. Scroll the JSON tree down 4 pages, then up 2.
 6. Switch Preview → Headers → Preview.
 7. Toggle the layout control (stacked ↔ side by side) once.
 8. Stop (time limit ends the recording).

Compare: hangs, worst frame, CPU samples, AX snapshot duration, RSS.
TEXT
}

case "${1:-help}" in
    prep) prep ;;
    launch) launch ;;
    record) shift; record "$@" ;;
    report) shift; report "$@" ;;
    scenario) scenario ;;
    *) sed -n '2,13p' "${BASH_SOURCE[0]}" ;;
esac
