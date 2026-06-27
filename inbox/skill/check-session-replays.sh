#!/usr/bin/env bash
# check-session-replays.sh — Analyze session recordings, investigate issues, email report
# Called by launchd every 20 minutes.
# Picks one unanalyzed device, triggers Gemini analysis, spawns Claude Code to investigate.

set -euo pipefail

source "$(dirname "$0")/lock.sh"
acquire_lock "check-session-replays" 3600

# Load secrets from analytics
ENV_FILE="$HOME/analytics/.env.production.local"
if [ -f "$ENV_FILE" ]; then
    export DATABASE_URL=$(grep '^DATABASE_URL=' "$ENV_FILE" | head -1 | sed 's/^DATABASE_URL=//' | tr -d '"')
    export RESEND_API_KEY=$(grep '^RESEND_API_KEY=' "$ENV_FILE" | sed 's/^RESEND_API_KEY=//' | tr -d '"' | tr -d '\\n')
    export POSTHOG_PERSONAL_API_KEY=$(grep '^POSTHOG_PERSONAL_API_KEY=' "$ENV_FILE" | sed 's/^POSTHOG_PERSONAL_API_KEY=//' | tr -d '"' | tr -d '\\n')
    export CRON_SECRET=$(grep '^CRON_SECRET=' "$ENV_FILE" | sed 's/^CRON_SECRET=//' | tr -d '"' | tr -d '\\n')
fi

# Also load from .env.local if production doesn't have everything
ENV_LOCAL="$HOME/analytics/.env.local"
if [ -f "$ENV_LOCAL" ]; then
    [ -z "${DATABASE_URL:-}" ] && export DATABASE_URL=$(grep '^DATABASE_URL=' "$ENV_LOCAL" | head -1 | sed 's/^DATABASE_URL=//' | tr -d '"')
    [ -z "${CRON_SECRET:-}" ] && export CRON_SECRET=$(grep '^CRON_SECRET=' "$ENV_LOCAL" | sed 's/^CRON_SECRET=//' | tr -d '"' | tr -d '\\n')
fi

# Firebase service account JSON is multi-line, needs Python to extract safely
for envf in "$ENV_FILE" "$ENV_LOCAL"; do
    if [ -z "${FIREBASE_SERVICE_ACCOUNT_JSON:-}" ] && [ -f "$envf" ]; then
        export FIREBASE_SERVICE_ACCOUNT_JSON=$(python3 -c "
import re
with open('$envf') as f:
    content = f.read()
m = re.search(r'FIREBASE_SERVICE_ACCOUNT_JSON=\"(.+?)\"(?:\n|\$)', content, re.DOTALL)
if m: print(m.group(1))
" 2>/dev/null || true)
    fi
done

export NODE_PATH="$HOME/analytics/node_modules"
INBOX_DIR="$HOME/fazm/inbox"
SCRIPTS_DIR="$INBOX_DIR/scripts"
LOG_DIR="$INBOX_DIR/skill/logs"
NODE_BIN="$HOME/.nvm/versions/node/v20.19.4/bin/node"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/session-replay-$(date +%Y-%m-%d_%H%M%S).log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

write_rotator_rejection_signal() {
    local reason="${1:-rate_limit}"
    local rotator_dir="$HOME/claude-account-rotator"
    local signal_path="$rotator_dir/rejection.signal"
    [ -d "$rotator_dir" ] || return 0

    cat > "$signal_path" <<JSON
{
  "status": "rejected",
  "rateLimitType": "five_hour",
  "utilization": null,
  "resetsAt": null,
  "observedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "fazm-session-replay",
  "reason": "$reason",
  "pid": $$
}
JSON
    log "Wrote rotator rejection signal: $signal_path ($reason)"
}

log "=== Session Replay Check: $(date) ==="

# Step 1: Find the next unanalyzed device
# Hard timeout so a hung HTTP/DB call can never wedge the launchd job. A missing
# timeout here left one run hung for ~17h on Jun 15 2026, which blocked every
# subsequent 20-min run (StartInterval jobs do not overlap).
DEVICE_JSON=$(gtimeout 120 "$NODE_BIN" "$SCRIPTS_DIR/check-unanalyzed-devices.js" 2>>"$LOG_FILE") || {
    rc=$?
    log "ERROR: check-unanalyzed-devices.js failed or timed out (exit $rc). Exiting; launchd retries next interval."
    exit 1
}

if [ "$DEVICE_JSON" = "null" ] || [ -z "$DEVICE_JSON" ]; then
    log "No unanalyzed devices found. Done."
    exit 0
fi

DEVICE_ID=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['deviceId'])")
USER_EMAIL=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('email') or 'unknown')")
USER_NAME=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('displayName') or d.get('email') or d['deviceId'])")
TOTAL_CHUNKS=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['totalChunks'])")
UNANALYZED=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['unanalyzedChunks'])")
NEEDS_GEMINI=$(echo "$DEVICE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('needsGeminiAnalysis', False))")

log "Selected device: $DEVICE_ID ($USER_NAME <$USER_EMAIL>)"
log "  Chunks: $TOTAL_CHUNKS total, $UNANALYZED unanalyzed, needsGemini=$NEEDS_GEMINI"

# Step 2: If device has unanalyzed chunks, analyze ONE bounded batch (up to 60).
# Large backlogs drain across multiple runs; investigation is deferred until the
# device is fully analyzed so we never run an expensive investigation on partial data.
ANALYSES_JSON=""
if [ "$NEEDS_GEMINI" = "True" ]; then
    log "Triggering Gemini analysis (bounded batch) for $UNANALYZED unanalyzed chunks..."
    # gtimeout caps the call above the trigger script's own 15-min poll window so a
    # stuck socket (no per-request timeout inside the node script) cannot hang forever.
    ANALYSES_JSON=$(gtimeout 1000 "$NODE_BIN" "$SCRIPTS_DIR/trigger-session-analysis.js" "$DEVICE_ID" 2>>"$LOG_FILE")
    EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        log "WARNING: Analysis trigger failed with code $EXIT_CODE"
        exit 1
    fi
    log "Gemini analysis batch complete."

    # If chunks remain, the device is mid-drain: skip investigation this run and
    # let the next run analyze the next batch. Avoids investigating partial data.
    REMAINING=$(curl -s --connect-timeout 15 --max-time 60 "${ORCHESTRATE_URL:-https://dash.m13v.com/api/session-recordings/orchestrate}?action=status&deviceId=$DEVICE_ID" \
        -H "Authorization: Bearer ${CRON_SECRET}" 2>>"$LOG_FILE" \
        | python3 -c "import json,sys; print(json.load(sys.stdin).get('unanalyzedChunks', 0))" 2>/dev/null || echo "0")
    if [ "$REMAINING" -gt 0 ] 2>/dev/null; then
        log "Device still has $REMAINING unanalyzed chunks; will keep draining on the next run. Deferring investigation."
        exit 0
    fi
    log "Device fully analyzed."
else
    log "All chunks already analyzed. Fetching existing analyses..."
    ANALYSES_JSON=$(curl -s --connect-timeout 15 --max-time 60 "${ORCHESTRATE_URL:-https://dash.m13v.com/api/session-recordings/orchestrate}?action=analyses&deviceId=$DEVICE_ID" \
        -H "Authorization: Bearer ${CRON_SECRET}" 2>>"$LOG_FILE")
fi

if [ -z "$ANALYSES_JSON" ]; then
    log "WARNING: No analysis data received. Exiting."
    exit 1
fi

ANALYSIS_COUNT=$(echo "$ANALYSES_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('count', 0))")
log "Got $ANALYSIS_COUNT analyses for device $DEVICE_ID"

# Step 3: Spawn Claude Code to investigate issues
PROMPT_FILE=$(mktemp)
OUTCOME_FILE="$LOG_DIR/outcome-${DEVICE_ID}-$(date +%Y%m%d_%H%M%S).json"

cat > "$PROMPT_FILE" <<PROMPT_EOF
Read ~/fazm/inbox/skill/SESSION-REPLAY-SKILL.md for the full workflow.

## Device to investigate

Device ID: $DEVICE_ID
User email: $USER_EMAIL
User name: $USER_NAME
Total chunks: $TOTAL_CHUNKS
Analyses: $ANALYSIS_COUNT

## Analysis results (from Gemini video analysis)

$ANALYSES_JSON

## Device metadata

$DEVICE_JSON

## Environment

The OUTCOME_FILE environment variable is set to: $OUTCOME_FILE
You MUST write a JSON outcome file to this path (see Step 5 in the skill doc).

Investigate this device's session recording analyses now. Follow the SESSION-REPLAY-SKILL.md workflow exactly.
PROMPT_EOF

log "Spawning Claude Code session for investigation..."
log "  Outcome file: $OUTCOME_FILE"
cd "$HOME/fazm"

CLAUDE_EXIT=0
gtimeout 2400 claude \
    -p "$(cat "$PROMPT_FILE")" \
    --dangerously-skip-permissions \
    2>&1 | tee -a "$LOG_FILE" || CLAUDE_EXIT=$?

rm -f "$PROMPT_FILE"

# Interpret Claude exit code
if [ $CLAUDE_EXIT -eq 124 ]; then
    log "ERROR: Claude Code timed out after 40 minutes"
elif [ $CLAUDE_EXIT -ne 0 ]; then
    log "WARNING: Claude Code exited with code $CLAUDE_EXIT (possible credit exhaustion or error)"
    if grep -Eqi "hit your session limit|hit your limit|rate limit|too many requests" "$LOG_FILE" 2>/dev/null; then
        write_rotator_rejection_signal "claude_exit_${CLAUDE_EXIT}"
    fi
fi

# Step 4: Validate outcome and mark as investigated
log "--- Post-run validation ---"

# Check outcome file
if [ -f "$OUTCOME_FILE" ]; then
    log "Outcome file found: $OUTCOME_FILE"
    cat "$OUTCOME_FILE" >> "$LOG_FILE"

    # Parse outcome
    USER_EMAIL_SENT=$(python3 -c "import json; d=json.load(open('$OUTCOME_FILE')); print(d.get('userEmailSent', False))" 2>/dev/null || echo "False")
    REPORT_EMAIL_SENT=$(python3 -c "import json; d=json.load(open('$OUTCOME_FILE')); print(d.get('reportEmailSent', False))" 2>/dev/null || echo "False")
    ISSUES_FOUND=$(python3 -c "import json; d=json.load(open('$OUTCOME_FILE')); print(d.get('issuesFound', 0))" 2>/dev/null || echo "0")
    BUGS_FIXED=$(python3 -c "import json; d=json.load(open('$OUTCOME_FILE')); print(d.get('bugsFixed', 0))" 2>/dev/null || echo "0")
    OUTCOME_SUMMARY=$(python3 -c "import json; d=json.load(open('$OUTCOME_FILE')); print(d.get('summary', 'No summary'))" 2>/dev/null || echo "No summary")

    log "  Issues found: $ISSUES_FOUND, Bugs fixed: $BUGS_FIXED"
    log "  User email sent: $USER_EMAIL_SENT, Report email sent: $REPORT_EMAIL_SENT"
    log "  Summary: $OUTCOME_SUMMARY"
else
    log "WARNING: No outcome file found. Claude agent may not have completed the workflow."
    USER_EMAIL_SENT="False"
    REPORT_EMAIL_SENT="False"
    ISSUES_FOUND="0"
    BUGS_FIXED="0"
    OUTCOME_SUMMARY="No outcome file produced"
fi

# Check if all chunks are analyzed
FINAL_STATUS=$(curl -s --connect-timeout 15 --max-time 60 "https://dash.m13v.com/api/session-recordings/orchestrate?action=status&deviceId=$DEVICE_ID" \
    -H "Authorization: Bearer ${CRON_SECRET}" 2>/dev/null)
FINAL_UNANALYZED=$(echo "$FINAL_STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('unanalyzedChunks', 0))" 2>/dev/null || echo "0")

# Decide whether to mark as investigated
SHOULD_MARK=true
MARK_REASON=""

if [ "$FINAL_UNANALYZED" -gt 0 ] 2>/dev/null; then
    SHOULD_MARK=false
    MARK_REASON="Device still has $FINAL_UNANALYZED unanalyzed chunks"
fi

# Per-session emails were removed: findings are recorded to the DB/dashboard and a
# weekly digest email is sent instead. Gate marking on the investigation actually
# completing (a valid outcome file with >=1 Gemini analysis), not on any email.
GEMINI_ANALYSIS_COUNT=$(python3 -c "import json; d=json.load(open('$OUTCOME_FILE')); print(d.get('geminiAnalysisCount', 0))" 2>/dev/null || echo "0")
if [ ! -f "$OUTCOME_FILE" ]; then
    SHOULD_MARK=false
    MARK_REASON="${MARK_REASON:+$MARK_REASON; }No outcome file produced"
elif [ "$GEMINI_ANALYSIS_COUNT" -lt 1 ] 2>/dev/null; then
    SHOULD_MARK=false
    MARK_REASON="${MARK_REASON:+$MARK_REASON; }Outcome reported 0 Gemini analyses"
fi

if $SHOULD_MARK; then
    log "Marking device as investigated: $OUTCOME_SUMMARY"
    "$NODE_BIN" "$SCRIPTS_DIR/mark-device-investigated.js" "$DEVICE_ID" "$OUTCOME_SUMMARY" "$OUTCOME_FILE" 2>>"$LOG_FILE" || log "WARNING: Failed to mark device $DEVICE_ID as investigated"
else
    log "NOT marking as investigated: $MARK_REASON"
    log "Device will be retried on next run."
fi

log "=== Done investigating device $DEVICE_ID (claude_exit=$CLAUDE_EXIT, marked=$SHOULD_MARK) ==="

# Cleanup old logs (keep 14 days)
find "$LOG_DIR" -name "session-replay-*.log" -mtime +14 -delete 2>/dev/null || true
