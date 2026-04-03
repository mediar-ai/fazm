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
    # Firebase service account (multi-line JSON, extract carefully)
    export FIREBASE_SERVICE_ACCOUNT_JSON=$(grep '^FIREBASE_SERVICE_ACCOUNT_JSON=' "$ENV_FILE" | sed 's/^FIREBASE_SERVICE_ACCOUNT_JSON=//' | tr -d '"')
fi

# Also load from .env.local if production doesn't have everything
ENV_LOCAL="$HOME/analytics/.env.local"
if [ -f "$ENV_LOCAL" ]; then
    [ -z "${DATABASE_URL:-}" ] && export DATABASE_URL=$(grep '^DATABASE_URL=' "$ENV_LOCAL" | head -1 | sed 's/^DATABASE_URL=//' | tr -d '"')
    [ -z "${CRON_SECRET:-}" ] && export CRON_SECRET=$(grep '^CRON_SECRET=' "$ENV_LOCAL" | sed 's/^CRON_SECRET=//' | tr -d '"' | tr -d '\\n')
    [ -z "${FIREBASE_SERVICE_ACCOUNT_JSON:-}" ] && export FIREBASE_SERVICE_ACCOUNT_JSON=$(grep '^FIREBASE_SERVICE_ACCOUNT_JSON=' "$ENV_LOCAL" | sed 's/^FIREBASE_SERVICE_ACCOUNT_JSON=//' | tr -d '"')
fi

export NODE_PATH="$HOME/analytics/node_modules"
INBOX_DIR="$HOME/fazm/inbox"
SCRIPTS_DIR="$INBOX_DIR/scripts"
LOG_DIR="$INBOX_DIR/skill/logs"
NODE_BIN="$HOME/.nvm/versions/node/v20.19.4/bin/node"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/session-replay-$(date +%Y-%m-%d_%H%M%S).log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

log "=== Session Replay Check: $(date) ==="

# Step 1: Find the next unanalyzed device
DEVICE_JSON=$("$NODE_BIN" "$SCRIPTS_DIR/check-unanalyzed-devices.js" 2>>"$LOG_FILE")

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

# Step 2: If device has unanalyzed chunks, trigger Gemini analysis and wait
ANALYSES_JSON=""
if [ "$NEEDS_GEMINI" = "True" ]; then
    log "Triggering Gemini analysis for $UNANALYZED chunks..."
    ANALYSES_JSON=$("$NODE_BIN" "$SCRIPTS_DIR/trigger-session-analysis.js" "$DEVICE_ID" 2>>"$LOG_FILE")
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 2 ]; then
        log "Device has too many chunks (>100). Skipping."
        # Mark as investigated with a note so we don't keep picking it
        "$NODE_BIN" "$SCRIPTS_DIR/mark-device-investigated.js" "$DEVICE_ID" "Skipped: too many chunks ($UNANALYZED)" 2>>"$LOG_FILE" || true
        exit 0
    elif [ $EXIT_CODE -ne 0 ]; then
        log "WARNING: Analysis trigger failed with code $EXIT_CODE"
        exit 1
    fi
    log "Gemini analysis complete."
else
    log "All chunks already analyzed. Fetching existing analyses..."
    ANALYSES_JSON=$(curl -s "${ORCHESTRATE_URL:-https://omi-analytics.vercel.app/api/session-recordings/orchestrate}?action=analyses&deviceId=$DEVICE_ID" \
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

Investigate this device's session recording analyses now. Follow the SESSION-REPLAY-SKILL.md workflow exactly.
PROMPT_EOF

log "Spawning Claude Code session for investigation..."
cd "$HOME/fazm"
gtimeout 2400 claude \
    -p "$(cat "$PROMPT_FILE")" \
    --dangerously-skip-permissions \
    2>&1 | tee -a "$LOG_FILE" || log "WARNING: Claude exited with code $?"

rm -f "$PROMPT_FILE"

# Step 4: Mark device as investigated
"$NODE_BIN" "$SCRIPTS_DIR/mark-device-investigated.js" "$DEVICE_ID" "Investigated $ANALYSIS_COUNT analyses" 2>>"$LOG_FILE" || log "WARNING: Failed to mark device $DEVICE_ID as investigated"

log "=== Done investigating device $DEVICE_ID ==="

# Cleanup old logs (keep 14 days)
find "$LOG_DIR" -name "session-replay-*.log" -mtime +14 -delete 2>/dev/null || true
