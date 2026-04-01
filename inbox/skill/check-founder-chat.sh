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

    # Immediately claim this chat by resetting unread_by_founder to 0
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
    (
        cd "$HOME/fazm"
        gtimeout 1200 claude \
            -p "$(cat "$PROMPT_FILE")" \
            --dangerously-skip-permissions \
            2>&1 | tee -a "$SESSION_LOG" || log "WARNING: Claude session for $EMAIL exited with code $?"
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
