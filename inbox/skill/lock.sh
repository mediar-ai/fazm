#!/bin/bash
# Portable file locking for macOS (no flock needed)
# Usage: source lock.sh; acquire_lock "platform-name" [timeout_seconds]

acquire_lock() {
  local name="$1"
  local timeout="${2:-3600}"
  local lock_dir="/tmp/fazm-inbox-${name}.lock"
  local waited=0

  while ! mkdir "$lock_dir" 2>/dev/null; do
    local should_remove=false
    if [ ! -f "$lock_dir/pid" ]; then
      should_remove=true
    else
      local holder_pid
      holder_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
      if [ -z "$holder_pid" ] || ! kill -0 "$holder_pid" 2>/dev/null; then
        should_remove=true
      fi
    fi

    # Safety net: remove any lock older than 3 hours regardless
    if [ -d "$lock_dir" ]; then
      local lock_age
      lock_age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || echo "0") ))
      if [ "$lock_age" -gt 10800 ]; then
        should_remove=true
      fi
    fi

    if $should_remove; then
      echo "Removing stale $name lock"
      rm -rf "$lock_dir"
      continue
    fi

    if [ "$waited" -ge "$timeout" ]; then
      echo "Previous $name run still active after $((timeout/60))min, skipping"
      exit 0
    fi
    sleep 10
    waited=$((waited + 10))
  done

  echo $$ > "$lock_dir/pid"
  trap 'rm -rf "'"$lock_dir"'"' EXIT INT TERM HUP
}
