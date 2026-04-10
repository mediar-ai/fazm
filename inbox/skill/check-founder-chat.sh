#!/usr/bin/env bash
# check-founder-chat.sh -- Check for unread founder chat messages
# Called by launchd every 15 seconds.
# For each user with unread messages, spawns a Claude session if one isn't already running.

set -euo pipefail

source "$(dirname "$0")/lock.sh"
acquire_lock "check-founder-chat" 60

# Load secrets from analytics (where the DB creds and API keys live)
# Can't source the file directly — it has multi-line JSON that breaks bash
ENV_FILE="$HOME/analytics/.env.production.local"
if [ -f "$ENV_FILE" ]; then
    export DATABASE_URL=$(grep '^DATABASE_URL=' "$ENV_FILE" | head -1 | sed 's/^DATABASE_URL=//' | tr -d '"')
    export RESEND_API_KEY=$(grep '^RESEND_API_KEY=' "$ENV_FILE" | sed 's/^RESEND_API_KEY=//' | tr -d '"' | tr -d '\\n')
    export POSTHOG_PERSONAL_API_KEY=$(grep '^POSTHOG_PERSONAL_API_KEY=' "$ENV_FILE" | sed 's/^POSTHOG_PERSONAL_API_KEY=//' | tr -d '"' | tr -d '\\n')
fi

export NODE_PATH="$HOME/analytics/node_modules"
NODE_BIN="$HOME/.nvm/versions/node/v20.19.4/bin/node"
INBOX_DIR="$HOME/fazm/inbox"
SCRIPTS_DIR="$INBOX_DIR/scripts"
LOG_DIR="$INBOX_DIR/skill/logs"

mkdir -p "$LOG_DIR"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG_DIR/founder-chat.log"; }

# Check for unread chats
CHATS=$("$NODE_BIN" "$SCRIPTS_DIR/check-unread-chats.js" 2>>"$LOG_DIR/founder-chat.log")

if [ "$CHATS" = "[]" ] || [ -z "$CHATS" ]; then
    exit 0
fi

# Parse each chat with unread messages
NUM_CHATS=$(echo "$CHATS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

for i in $(seq 0 $((NUM_CHATS - 1))); do
    UID_VAL=$(echo "$CHATS" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i]['uid'])")
    EMAIL=$(echo "$CHATS" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i]['email'])")
    NAME=$(echo "$CHATS" | python3 -c "import json,sys; d=json.load(sys.stdin)[$i]; print(d.get('name') or d['email'])")
    UNREAD=$(echo "$CHATS" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i]['unread'])")

    PID_FILE="/tmp/fazm-chat-${UID_VAL}.pid"

    # Check if we're rate limited — skip all spawns until the limit resets
    if [ -f "/tmp/fazm-chat-ratelimit" ]; then
        RL_TS=$(awk '{print $2}' /tmp/fazm-chat-ratelimit 2>/dev/null || echo "0")
        NOW_TS=$(date +%s)
        # Rate limit marker expires after 1 hour (3600s) — by then the limit should have reset
        if [ $((NOW_TS - RL_TS)) -lt 3600 ]; then
            continue
        else
            rm -f /tmp/fazm-chat-ratelimit
        fi
    fi

    # Check if a Claude session is already running for this user
    if [ -f "$PID_FILE" ]; then
        EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
            log "Session already active for $EMAIL (pid $EXISTING_PID), skipping"
            continue
        fi
        # Stale PID file, clean up
        rm -f "$PID_FILE"
    fi

    log "Spawning session for $EMAIL ($UNREAD unread)"

    # Check cooldown first — if another session recently handled this user, skip
    if ! "$NODE_BIN" "$SCRIPTS_DIR/claim-chat.js" "$UID_VAL" --check-only 2>>"$LOG_DIR/founder-chat.log"; then
        log "Chat for $EMAIL is in cooldown, skipping"
        continue
    fi

    # Claim this chat (resets unread_by_founder=0, sets 5-min cooldown)
    # Prevents duplicate spawns if the Claude session finishes before next poll
    "$NODE_BIN" "$SCRIPTS_DIR/claim-chat.js" "$UID_VAL" 2>>"$LOG_DIR/founder-chat.log" || log "WARNING: Failed to claim chat for $UID_VAL"

    # Extract this user's data as JSON for the prompt
    USER_DATA=$(echo "$CHATS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)[$i], indent=2))")

    # Build prompt
    PROMPT_FILE=$(mktemp)
    cat > "$PROMPT_FILE" <<PROMPT_EOF
Read ~/fazm/inbox/skill/FOUNDER-CHAT-SKILL.md for the full workflow.

## Chat to handle

User UID: $UID_VAL
User Email: $EMAIL
User Name: $NAME
Unread messages: $UNREAD

Full conversation data (all messages in order):
$USER_DATA

Process this chat now. Follow the FOUNDER-CHAT-SKILL.md workflow exactly.
Remember to remove the PID file /tmp/fazm-chat-${UID_VAL}.pid when you're done.
PROMPT_EOF

    # Spawn Claude in background
    SESSION_LOG="$LOG_DIR/chat-session-${UID_VAL}-$(date +%Y%m%d_%H%M%S).log"
    FAIL_COUNT_FILE="/tmp/fazm-chat-fail-${UID_VAL}"
    (
        set +e  # Don't exit on error — we need cleanup to run
        cd "$HOME/fazm"
        echo "[$(date)] Starting Claude session for $EMAIL" >> "$SESSION_LOG"
        gtimeout 1200 claude \
            -p "$(cat "$PROMPT_FILE")" \
            --dangerously-skip-permissions \
            >> "$SESSION_LOG" 2>&1
        EXIT_CODE=$?
        echo "[$(date)] Claude exited with code $EXIT_CODE" >> "$SESSION_LOG"
        if [ $EXIT_CODE -ne 0 ]; then
            echo "[$(date)] WARNING: Claude session for $EMAIL exited with code $EXIT_CODE" >> "$LOG_DIR/founder-chat.log"

            # Check if this is a rate limit error — don't retry, just wait for reset
            if grep -qi "hit your limit\|rate limit\|too many requests" "$SESSION_LOG" 2>/dev/null; then
                echo "[$(date)] RATE LIMITED: Not retrying $EMAIL until limit resets" >> "$LOG_DIR/founder-chat.log"
                # Leave chat claimed (don't unclaim) so it stops retrying
                # Write a marker so the next poll knows to skip
                echo "rate_limited $(date +%s)" > "/tmp/fazm-chat-ratelimit"
                rm -f "$PROMPT_FILE" "$PID_FILE" "$FAIL_COUNT_FILE"
                exit 0
            fi

            # Track consecutive failures — stop retrying after 3
            FAILS=0
            [ -f "$FAIL_COUNT_FILE" ] && FAILS=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo "0")
            FAILS=$((FAILS + 1))
            echo "$FAILS" > "$FAIL_COUNT_FILE"

            if [ "$FAILS" -ge 3 ]; then
                echo "[$(date)] GIVING UP on $EMAIL after $FAILS consecutive failures" >> "$LOG_DIR/founder-chat.log"
                rm -f "$FAIL_COUNT_FILE"
                # Don't unclaim — leave it so it doesn't retry endlessly
            else
                # Re-set unread so the message gets retried on next poll
                NODE_PATH="$HOME/analytics/node_modules" "$HOME/.nvm/versions/node/v20.19.4/bin/node" \
                    "$HOME/fazm/inbox/scripts/unclaim-chat.js" "$UID_VAL" >> "$LOG_DIR/founder-chat.log" 2>&1
                echo "[$(date)] Unclaimed chat for $EMAIL (will retry, attempt $FAILS/3)" >> "$LOG_DIR/founder-chat.log"
            fi
        else
            # Success — reset failure counter
            rm -f "$FAIL_COUNT_FILE"
        fi
        # Also check if Claude produced meaningful output (more than just the startup line)
        LINE_COUNT=$(wc -l < "$SESSION_LOG" 2>/dev/null || echo "0")
        if [ "$LINE_COUNT" -le 2 ] && [ "$EXIT_CODE" -eq 0 ]; then
            echo "[$(date)] WARNING: Claude session for $EMAIL produced no output (possible rate limit)" >> "$LOG_DIR/founder-chat.log"
            NODE_PATH="$HOME/analytics/node_modules" "$HOME/.nvm/versions/node/v20.19.4/bin/node" \
                "$HOME/fazm/inbox/scripts/unclaim-chat.js" "$UID_VAL" >> "$LOG_DIR/founder-chat.log" 2>&1
            echo "[$(date)] Unclaimed chat for $EMAIL (will retry)" >> "$LOG_DIR/founder-chat.log"
        fi
        rm -f "$PROMPT_FILE" "$PID_FILE"
    ) &

    CLAUDE_PID=$!
    echo "$CLAUDE_PID" > "$PID_FILE"
    log "Started session for $EMAIL (pid $CLAUDE_PID)"
done

# Trim founder-chat.log to last 2000 lines
if [ -f "$LOG_DIR/founder-chat.log" ]; then
    tail -2000 "$LOG_DIR/founder-chat.log" > "$LOG_DIR/founder-chat.log.tmp" 2>/dev/null && \
        mv "$LOG_DIR/founder-chat.log.tmp" "$LOG_DIR/founder-chat.log" || true
fi
