#!/usr/bin/env bash
# check-queries.sh — Analyze recent user queries for patterns, issues, and improvement opportunities
# Called by launchd every 6 hours.
# Fetches queries since last analysis, spawns Claude Code to investigate patterns.

set -euo pipefail

source "$(dirname "$0")/lock.sh"
acquire_lock "check-queries" 3600

# Load secrets from analytics
ENV_FILE="$HOME/analytics/.env.production.local"
if [ -f "$ENV_FILE" ]; then
    export DATABASE_URL=$(grep '^DATABASE_URL=' "$ENV_FILE" | head -1 | sed 's/^DATABASE_URL=//' | tr -d '"')
    export RESEND_API_KEY=$(grep '^RESEND_API_KEY=' "$ENV_FILE" | sed 's/^RESEND_API_KEY=//' | tr -d '"' | tr -d '\\n')
    export POSTHOG_PERSONAL_API_KEY=$(grep '^POSTHOG_PERSONAL_API_KEY=' "$ENV_FILE" | sed 's/^POSTHOG_PERSONAL_API_KEY=//' | tr -d '"' | tr -d '\\n')
fi

# Also load from .env.local if production doesn't have everything
ENV_LOCAL="$HOME/analytics/.env.local"
if [ -f "$ENV_LOCAL" ]; then
    [ -z "${DATABASE_URL:-}" ] && export DATABASE_URL=$(grep '^DATABASE_URL=' "$ENV_LOCAL" | head -1 | sed 's/^DATABASE_URL=//' | tr -d '"')
fi

export NODE_PATH="$HOME/analytics/node_modules"
INBOX_DIR="$HOME/fazm/inbox"
SCRIPTS_DIR="$INBOX_DIR/scripts"
LOG_DIR="$INBOX_DIR/skill/logs"
NODE_BIN="$HOME/.nvm/versions/node/v20.19.4/bin/node"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/claude-account-rotator/bin/claude}"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/queries-$(date +%Y-%m-%d_%H%M%S).log"

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
  "source": "fazm-query-analysis",
  "reason": "$reason",
  "pid": $$
}
JSON
    log "Wrote rotator rejection signal: $signal_path ($reason)"
}

log "=== User Queries Analysis: $(date) ==="

# Step 1: Fetch queries since last analysis
QUERIES=$("$NODE_BIN" "$SCRIPTS_DIR/fetch-queries.js" --limit 500 2>>"$LOG_FILE")

if [ "$QUERIES" = "[]" ] || [ -z "$QUERIES" ]; then
    log "No new queries since last analysis. Done."
    exit 0
fi

QUERY_COUNT=$(echo "$QUERIES" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
LATEST_TS=$(echo "$QUERIES" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['timestamp'])")
OLDEST_TS=$(echo "$QUERIES" | python3 -c "import json,sys; qs=json.load(sys.stdin); print(qs[-1]['timestamp'])")
UNIQUE_USERS=$(echo "$QUERIES" | python3 -c "import json,sys; print(len(set(q['personId'] for q in json.load(sys.stdin))))")

log "Found $QUERY_COUNT queries from $UNIQUE_USERS users"
log "  Time range: $OLDEST_TS to $LATEST_TS"

# Step 2: Spawn Claude Code to analyze patterns
PROMPT_FILE=$(mktemp)
OUTCOME_FILE="$LOG_DIR/outcome-queries-$(date +%Y%m%d_%H%M%S).json"

cat > "$PROMPT_FILE" <<PROMPT_EOF
Read ~/fazm/inbox/skill/QUERIES-SKILL.md for the full workflow.

## Queries to analyze

Query count: $QUERY_COUNT
Unique users: $UNIQUE_USERS
Time range: $OLDEST_TS to $LATEST_TS

Full query data (JSON):
$QUERIES

## Environment

The OUTCOME_FILE environment variable is set to: $OUTCOME_FILE
You MUST write a JSON outcome file to this path (see the skill doc).

Analyze these queries now. Follow the QUERIES-SKILL.md workflow exactly.
PROMPT_EOF

log "Spawning Claude Code session for analysis..."
log "  Outcome file: $OUTCOME_FILE"
cd "$HOME/fazm"

CLAUDE_EXIT=0
gtimeout 1800 "$CLAUDE_BIN" \
    -p "$(cat "$PROMPT_FILE")" \
    --dangerously-skip-permissions \
    2>&1 | tee -a "$LOG_FILE" || CLAUDE_EXIT=$?

rm -f "$PROMPT_FILE"

# Interpret Claude exit code
if [ $CLAUDE_EXIT -eq 124 ]; then
    log "ERROR: Claude Code timed out after 30 minutes"
elif [ $CLAUDE_EXIT -ne 0 ]; then
    log "WARNING: Claude Code exited with code $CLAUDE_EXIT"
    if grep -Eqi "hit your session limit|hit your limit|rate limit|too many requests" "$LOG_FILE" 2>/dev/null; then
        write_rotator_rejection_signal "claude_exit_${CLAUDE_EXIT}"
    fi
fi

# Step 3: Validate outcome and mark as analyzed
log "--- Post-run validation ---"

SHOULD_MARK=true
MARK_REASON=""

if [ -f "$OUTCOME_FILE" ]; then
    log "Outcome file found: $OUTCOME_FILE"
    cat "$OUTCOME_FILE" >> "$LOG_FILE"

    REPORT_SENT=$(python3 -c "import json; d=json.load(open('$OUTCOME_FILE')); print(d.get('reportEmailSent', False))" 2>/dev/null || echo "False")
    FINDINGS_COUNT=$(python3 -c "import json; d=json.load(open('$OUTCOME_FILE')); print(d.get('findingsCount', 0))" 2>/dev/null || echo "0")
    OUTCOME_SUMMARY=$(python3 -c "import json; d=json.load(open('$OUTCOME_FILE')); print(d.get('summary', 'No summary'))" 2>/dev/null || echo "No summary")

    log "  Findings: $FINDINGS_COUNT, Report sent: $REPORT_SENT"
    log "  Summary: $OUTCOME_SUMMARY"

    # Report is only required if there were findings
    if [ "$FINDINGS_COUNT" != "0" ] && [ "$REPORT_SENT" != "True" ]; then
        SHOULD_MARK=false
        MARK_REASON="Findings found but report email was not sent"
    fi
else
    log "WARNING: No outcome file found. Claude agent may not have completed the workflow."
    SHOULD_MARK=false
    MARK_REASON="No outcome file produced"
fi

if $SHOULD_MARK; then
    log "Marking queries as analyzed up to $LATEST_TS"
    "$NODE_BIN" "$SCRIPTS_DIR/mark-queries-analyzed.js" "$LATEST_TS" "$QUERY_COUNT" "$OUTCOME_FILE" 2>>"$LOG_FILE" || log "WARNING: Failed to mark queries as analyzed"
else
    log "NOT marking as analyzed: $MARK_REASON"
    log "Will retry on next run."
fi

log "=== Done analyzing $QUERY_COUNT queries (claude_exit=$CLAUDE_EXIT, marked=$SHOULD_MARK) ==="

# Cleanup old logs (keep 14 days)
find "$LOG_DIR" -name "queries-*.log" -mtime +14 -delete 2>/dev/null || true
find "$LOG_DIR" -name "outcome-queries-*.json" -mtime +14 -delete 2>/dev/null || true
