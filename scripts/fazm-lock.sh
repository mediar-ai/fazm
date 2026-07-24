#!/bin/bash
# Shared file-based lock for Fazm build/run scripts.
# Serializes build/install across agents, and waits when another agent is
# actively testing the running app (detected via log tailing).
#
# Usage:
#   source scripts/fazm-lock.sh
#   fazm_acquire_lock [timeout_seconds]   # default: 300 (5 min)
#   fazm_release_lock                     # manual release (also runs on EXIT)
#
# The lock is automatically released on EXIT (including Ctrl+C, errors, etc.).

FAZM_LOCK_FILE="/tmp/fazm-build.lock"
FAZM_DEV_LOG="/private/tmp/fazm-dev.log"

# Window (seconds) to consider the app "actively tested" after the most
# recent chat/test/control activity line in the log.
FAZM_IDLE_WINDOW_SEC="${FAZM_IDLE_WINDOW_SEC:-30}"

# Log patterns that indicate another agent is actively testing the app.
# Background noise (GeminiAnalysis, resizeAnchored, Posthog batching) is
# intentionally excluded — only user/agent-driven activity counts.
FAZM_ACTIVITY_PATTERN='Chat query started|Test query received|Chat response complete|Control command received|PushToTalkManager: started listening|floating_bar_query_sent|floating_bar_ptt_started|chat_agent_query_completed'

# Returns 0 (true) if the app has been idle for at least FAZM_IDLE_WINDOW_SEC.
# Returns 1 (false) if a recent activity line was found in the log.
# Also prints a one-line reason when returning false.
fazm_app_is_idle() {
    [ -f "$FAZM_DEV_LOG" ] || return 0

    # Scan the tail of the log (last 2000 lines covers ~15 min of busy activity)
    # for the most recent line matching our activity pattern.
    local last_line
    last_line=$(tail -2000 "$FAZM_DEV_LOG" 2>/dev/null | grep -E "$FAZM_ACTIVITY_PATTERN" | tail -1)
    [ -z "$last_line" ] && return 0  # no activity ever logged → idle

    # Extract [HH:MM:SS from the line prefix
    local hms
    hms=$(printf '%s' "$last_line" | sed -nE 's/^\[([0-9]{2}:[0-9]{2}:[0-9]{2}).*/\1/p')
    [ -z "$hms" ] && return 0  # can't parse → treat as idle

    local today
    today=$(date +%Y-%m-%d)
    local activity_ts
    activity_ts=$(date -j -f "%Y-%m-%d %H:%M:%S" "$today $hms" +%s 2>/dev/null)
    [ -z "$activity_ts" ] && return 0

    local now
    now=$(date +%s)

    # Day rollover: if the computed timestamp is in the future, it must be
    # yesterday's log line (we ran past midnight).
    if [ "$activity_ts" -gt "$now" ]; then
        activity_ts=$((activity_ts - 86400))
    fi

    local age=$((now - activity_ts))
    if [ "$age" -lt "$FAZM_IDLE_WINDOW_SEC" ]; then
        # Emit reason on stderr so acquire_lock can log it cleanly
        local marker
        marker=$(printf '%s' "$last_line" | grep -oE "$FAZM_ACTIVITY_PATTERN" | head -1)
        echo "[fazm-lock]   last activity: '$marker' at $hms (${age}s ago, idle window=${FAZM_IDLE_WINDOW_SEC}s)" >&2
        return 1
    fi

    return 0
}

fazm_acquire_lock() {
    local timeout="${1:-300}"
    local waited=0
    local waiting_for_idle_logged=0

    while true; do
        # Try to create lock atomically via mkdir (atomic on all filesystems)
        if mkdir "$FAZM_LOCK_FILE" 2>/dev/null; then
            # Won the lock — write our PID for stale detection
            echo "$$" > "$FAZM_LOCK_FILE/pid"
            echo "$(basename "$0")" > "$FAZM_LOCK_FILE/script"

            # Before committing to the lock, check if another agent is actively
            # testing the running app. If so, release and wait for idle —
            # rebuilding now would kill their app mid-test.
            if ! fazm_app_is_idle; then
                if [ "$waiting_for_idle_logged" -eq 0 ]; then
                    echo "[fazm-lock] App is being actively tested by another agent. Waiting for idle..."
                    waiting_for_idle_logged=1
                fi
                rm -rf "$FAZM_LOCK_FILE"
                if [ "$waited" -ge "$timeout" ]; then
                    echo "[fazm-lock] ERROR: Timed out after ${timeout}s waiting for app to go idle"
                    exit 1
                fi
                sleep 5
                waited=$((waited + 5))
                continue
            fi

            trap fazm_release_lock EXIT
            return 0
        fi

        # Lock exists — check if the holder is still alive
        local holder_pid
        holder_pid=$(cat "$FAZM_LOCK_FILE/pid" 2>/dev/null || true)
        local holder_script
        holder_script=$(cat "$FAZM_LOCK_FILE/script" 2>/dev/null || echo "unknown")

        if [ -z "$holder_pid" ]; then
            if rmdir "$FAZM_LOCK_FILE" 2>/dev/null; then
                echo "[fazm-lock] Removing stale empty lock with no holder PID"
                continue
            fi
        fi

        if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
            # Holder is dead — stale lock, remove and retry immediately
            echo "[fazm-lock] Removing stale lock from dead process $holder_pid ($holder_script)"
            rm -rf "$FAZM_LOCK_FILE"
            continue
        fi

        # Holder is alive — wait
        if [ "$waited" -ge "$timeout" ]; then
            echo "[fazm-lock] ERROR: Timed out after ${timeout}s waiting for lock held by PID $holder_pid ($holder_script)"
            echo "[fazm-lock] If this is stuck, manually run: rm -rf $FAZM_LOCK_FILE"
            exit 1
        fi

        if [ "$waited" -eq 0 ]; then
            echo "[fazm-lock] Another agent is running $holder_script (PID $holder_pid). Waiting..."
        fi

        sleep 5
        waited=$((waited + 5))

        # Print progress every 30 seconds
        if [ $((waited % 30)) -eq 0 ]; then
            echo "[fazm-lock] Still waiting... (${waited}s / ${timeout}s timeout)"
        fi
    done
}

fazm_release_lock() {
    # Only release if we own it
    local holder_pid
    holder_pid=$(cat "$FAZM_LOCK_FILE/pid" 2>/dev/null)
    if [ "$holder_pid" = "$$" ]; then
        rm -rf "$FAZM_LOCK_FILE"
    fi
}
