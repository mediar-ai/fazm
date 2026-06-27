#!/usr/bin/env bash
# check-inbound.sh — Process new FAZM inbound emails one at a time
# Called by launchd every 5 minutes.
# For each new inbound email, spins up a full Claude Code session in the FAZM repo.

set -euo pipefail

source "$(dirname "$0")/lock.sh"
acquire_lock "check-inbound" 3600

# Load secrets from analytics (where the DB creds live)
# Can't source the file directly — it has multi-line JSON that breaks bash
ENV_FILE="$HOME/analytics/.env.production.local"
if [ -f "$ENV_FILE" ]; then
    export DATABASE_URL=$(grep '^DATABASE_URL=' "$ENV_FILE" | head -1 | sed 's/^DATABASE_URL=//' | tr -d '"')
    export RESEND_API_KEY=$(grep '^RESEND_API_KEY=' "$ENV_FILE" | sed 's/^RESEND_API_KEY=//' | tr -d '"' | tr -d '\\n')
    export POSTHOG_PERSONAL_API_KEY=$(grep '^POSTHOG_PERSONAL_API_KEY=' "$ENV_FILE" | sed 's/^POSTHOG_PERSONAL_API_KEY=//' | tr -d '"' | tr -d '\\n')
fi

export NODE_PATH="$HOME/analytics/node_modules"
INBOX_DIR="$HOME/fazm/inbox"
SCRIPTS_DIR="$INBOX_DIR/scripts"
LOG_DIR="$INBOX_DIR/skill/logs"
NODE_BIN="$HOME/.nvm/versions/node/v20.19.4/bin/node"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/claude-account-rotator/bin/claude}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/check-inbound-$(date +%Y-%m-%d_%H%M%S).log"

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
  "source": "fazm-inbound",
  "reason": "$reason",
  "pid": $$
}
JSON
    log "Wrote rotator rejection signal: $signal_path ($reason)"
}

log "=== FAZM Inbox Check: $(date) ==="

# Check for new unprocessed inbound emails
EMAILS=$("$NODE_BIN" "$SCRIPTS_DIR/check-new-inbound.js" 2>>"$LOG_FILE")

if [ "$EMAILS" = "[]" ] || [ -z "$EMAILS" ]; then
    log "No new inbound emails. Done."
    exit 0
fi

# Parse emails (may be multiple from the same user)
EMAIL_IDS=$(echo "$EMAILS" | python3 -c "import json,sys; print(' '.join(str(e['email_id']) for e in json.load(sys.stdin)))")
EMAIL_COUNT=$(echo "$EMAILS" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
SENDER_EMAIL=$(echo "$EMAILS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['sender_email'])")
SENDER_NAME=$(echo "$EMAILS" | python3 -c "import json,sys; d=json.load(sys.stdin)[0]; print(d.get('sender_name') or d['sender_email'])")
SUBJECTS=$(echo "$EMAILS" | python3 -c "import json,sys; print(' | '.join(e.get('subject','(no subject)') for e in json.load(sys.stdin)))")
WORKFLOW_USER_ID=$(echo "$EMAILS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['workflow_user_id'])")

log "Processing $EMAIL_COUNT email(s) [#$EMAIL_IDS] from $SENDER_EMAIL: $SUBJECTS"

# Build the prompt for Claude
PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<PROMPT_EOF
Read ~/fazm/inbox/SKILL.md for the full workflow.

## Emails to process

Email IDs: $EMAIL_IDS
Email count: $EMAIL_COUNT
Workflow User ID: $WORKFLOW_USER_ID
Sender: $SENDER_NAME <$SENDER_EMAIL>

Full email data (including thread history):
$EMAILS

Process these emails now. There are $EMAIL_COUNT unprocessed inbound email(s) from this user. Treat them as one batch: investigate all issues mentioned across all emails, then send ONE combined reply addressing everything. Follow the SKILL.md workflow exactly.
PROMPT_EOF

# Run Claude Code with full permissions in the FAZM repo
log "Spawning Claude Code session..."
cd "$HOME/fazm"
set +e
gtimeout 1800 "$CLAUDE_BIN" \
    -p "$(cat "$PROMPT_FILE")" \
    --dangerously-skip-permissions \
    2>&1 | tee -a "$LOG_FILE"
CLAUDE_EXIT=${PIPESTATUS[0]}
set -e

rm -f "$PROMPT_FILE"

# Decide whether it is safe to mark these emails as processed.
# Only mark on a clean exit AND no Anthropic usage-cap message in the run log.
# Anything else means the agent didn't actually do the work; leave the rows
# unprocessed so the next launchd tick retries instead of silently dropping them.
SAFE_TO_MARK=1
if [ "$CLAUDE_EXIT" -ne 0 ]; then
    log "WARNING: Claude exited with code $CLAUDE_EXIT — leaving emails [#$EMAIL_IDS] unprocessed for retry"
    SAFE_TO_MARK=0
    if grep -Eqi "hit your session limit|hit your limit|rate limit|too many requests|Claude AI usage limit reached|You're out of extra usage|You've hit your org's monthly usage limit" "$LOG_FILE"; then
        write_rotator_rejection_signal "claude_exit_${CLAUDE_EXIT}"
    fi
fi
if grep -qE "^(You're out of extra usage|You've hit your org's monthly usage limit|Claude AI usage limit reached|You've hit your session limit)" "$LOG_FILE"; then
    log "WARNING: Anthropic usage-cap message in run log — leaving emails [#$EMAIL_IDS] unprocessed for retry"
    SAFE_TO_MARK=0
    write_rotator_rejection_signal "usage_cap_message"
fi

if [ "$SAFE_TO_MARK" -eq 1 ]; then
    "$NODE_BIN" "$SCRIPTS_DIR/mark-processed.js" $EMAIL_IDS 2>>"$LOG_FILE" || log "WARNING: Failed to mark emails $EMAIL_IDS as processed"
    log "=== Done processing $EMAIL_COUNT email(s) [#$EMAIL_IDS] ==="
else
    log "=== Skipped marking $EMAIL_COUNT email(s) [#$EMAIL_IDS] — will retry on next tick ==="
fi

# Cleanup old logs (keep 14 days)
find "$LOG_DIR" -name "check-inbound-*.log" -mtime +14 -delete 2>/dev/null || true
