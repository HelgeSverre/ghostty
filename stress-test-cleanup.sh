#!/bin/bash
# Stress test for surface cleanup
# Rapidly creates/closes tabs to try to trigger memory leaks

set -e

GHOSTTY_APP="${1:-/Users/helge/code/ghostty/zig-out/Ghostty.app}"
ITERATIONS="${2:-50}"
UNDO_TIMEOUT=5

echo "=== Ghostty Cleanup Stress Test ==="
echo "App: $GHOSTTY_APP"
echo "Iterations: $ITERATIONS"
echo ""

# Kill any existing Ghostty
pkill -x ghostty 2>/dev/null || true
sleep 2

# Start Ghostty
echo "Starting Ghostty..."
open "$GHOSTTY_APP"
sleep 4

GHOSTTY_PID=$(pgrep -x ghostty | head -1)
if [ -z "$GHOSTTY_PID" ]; then
    echo "ERROR: Could not find Ghostty process"
    exit 1
fi
echo "PID: $GHOSTTY_PID"

# Get baseline
get_memory() {
    ps -o rss= -p "$1" 2>/dev/null | awk '{print $1}' || echo "0"
}

get_children() {
    pgrep -P "$1" 2>/dev/null | wc -l | tr -d ' '
}

get_vm_regions() {
    vmmap --summary "$1" 2>/dev/null | grep "^VM_ALLOCATE" | awk '{print $NF}' || echo "0"
}

BASELINE_MEM=$(get_memory $GHOSTTY_PID)
BASELINE_CHILDREN=$(get_children $GHOSTTY_PID)
BASELINE_REGIONS=$(get_vm_regions $GHOSTTY_PID)

echo ""
echo "Baseline: ${BASELINE_MEM}KB memory, $BASELINE_CHILDREN children, $BASELINE_REGIONS VM regions"
echo ""

# Function to create and close a tab with splits
cycle_tab() {
    osascript <<'EOF' 2>/dev/null
tell application "ghostty" to activate
delay 0.3

tell application "System Events"
    tell process "ghostty"
        -- New tab
        keystroke "t" using {command down}
        delay 0.3

        -- Split right
        keystroke "d" using {command down}
        delay 0.2

        -- Split down
        keystroke "d" using {command down, shift down}
        delay 0.2

        -- Close tab
        keystroke "w" using {command down, option down}
        delay 0.1
    end tell
end tell
EOF
}

echo "Running $ITERATIONS iterations of create/close cycles..."
echo "(Each cycle: new tab → split right → split down → close tab)"
echo ""

# Track stats over time
for i in $(seq 1 $ITERATIONS); do
    cycle_tab

    # Every 10 iterations, check stats
    if [ $((i % 10)) -eq 0 ]; then
        # Wait for undo to expire
        sleep $((UNDO_TIMEOUT + 1))

        MEM=$(get_memory $GHOSTTY_PID)
        CHILDREN=$(get_children $GHOSTTY_PID)
        REGIONS=$(get_vm_regions $GHOSTTY_PID)

        MEM_GROWTH=$((MEM - BASELINE_MEM))
        CHILD_GROWTH=$((CHILDREN - BASELINE_CHILDREN))
        REGION_GROWTH=$((REGIONS - BASELINE_REGIONS))

        printf "Iteration %3d: %6dKB (+%6dKB), %2d children (+%d), %3d regions (+%d)\n" \
            "$i" "$MEM" "$MEM_GROWTH" "$CHILDREN" "$CHILD_GROWTH" "$REGIONS" "$REGION_GROWTH"

        # Check for leaks
        if [ "$CHILD_GROWTH" -gt 5 ]; then
            echo ""
            echo "⚠️  WARNING: Possible orphaned processes detected!"
        fi
        if [ "$REGION_GROWTH" -gt 50 ]; then
            echo ""
            echo "⚠️  WARNING: Possible memory leak detected!"
        fi
    fi
done

echo ""
echo "Waiting for final undo expiration..."
sleep $((UNDO_TIMEOUT + 2))

# Final stats
FINAL_MEM=$(get_memory $GHOSTTY_PID)
FINAL_CHILDREN=$(get_children $GHOSTTY_PID)
FINAL_REGIONS=$(get_vm_regions $GHOSTTY_PID)

echo ""
echo "=========================================="
echo "              FINAL RESULTS"
echo "=========================================="
echo ""
echo "                    Baseline    Final       Growth"
echo "Memory (KB):        $BASELINE_MEM        $FINAL_MEM        +$((FINAL_MEM - BASELINE_MEM))"
echo "Children:           $BASELINE_CHILDREN           $FINAL_CHILDREN           +$((FINAL_CHILDREN - BASELINE_CHILDREN))"
echo "VM Regions:         $BASELINE_REGIONS         $FINAL_REGIONS         +$((FINAL_REGIONS - BASELINE_REGIONS))"
echo ""

# Determine pass/fail
LEAKED_CHILDREN=$((FINAL_CHILDREN - BASELINE_CHILDREN))
LEAKED_REGIONS=$((FINAL_REGIONS - BASELINE_REGIONS))

if [ "$LEAKED_CHILDREN" -gt 2 ]; then
    echo "❌ FAIL: $LEAKED_CHILDREN orphaned child processes"
    echo ""
    echo "Orphaned processes:"
    pgrep -P $GHOSTTY_PID 2>/dev/null | while read pid; do
        ps -p "$pid" -o pid,ppid,stat,comm 2>/dev/null
    done
    RESULT=1
elif [ "$LEAKED_REGIONS" -gt 20 ]; then
    echo "❌ FAIL: $LEAKED_REGIONS leaked VM regions"
    RESULT=1
else
    echo "✅ PASS: No significant leaks detected after $ITERATIONS cycles"
    RESULT=0
fi

echo ""
echo "Quitting Ghostty..."
osascript -e 'tell application "ghostty" to quit' 2>/dev/null || true

exit $RESULT
