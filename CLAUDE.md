# Claude Project Context

## Project Overview
Fazm — a macOS desktop app (Swift). Open source at github.com/mediar-ai/fazm.

## Inbox Pipelines

Four launchd services run autonomous agents that handle inbound communication and recurring tasks. Pausing/resuming preserves all config and DB state; pipelines pick up where they left off.

| Service | Plist | Interval | Purpose |
|---------|-------|----------|---------|
| Email inbox | `com.m13v.fazm-inbox` | 5 min | Replies to unanswered inbound emails |
| Founder chat | `com.m13v.fazm-founder-chat` | 15 sec | Responds to in-app chat messages |
| Session replay | `com.m13v.fazm-session-replay` | 20 min | Analyzes session recordings for bugs |
| Routines | `com.m13v.fazm-routines` | 60 sec | Polls `cron_jobs` table and fires due user routines |

**Check status:** `launchctl list | grep fazm`

**Pause all:**
```bash
for s in inbox founder-chat session-replay routines; do launchctl unload ~/Library/LaunchAgents/com.m13v.fazm-$s.plist; done
```

**Resume all:**
```bash
for s in inbox founder-chat session-replay routines; do launchctl load ~/Library/LaunchAgents/com.m13v.fazm-$s.plist; done
```

**Pause/resume one:** replace the loop with a single `launchctl unload/load` targeting the specific plist.

Pipeline code lives in `inbox/` (plists in `inbox/launchd/`, Node.js scripts in `inbox/scripts/`, Claude skills in `inbox/skill/`). The SEO inbox (`com.m13v.fazm-seo-inbox`) is a separate pipeline in `~/fazm-website/seo/inbox/`.

## Routines (recurring AI tasks)

User-defined recurring AI tasks. The `routines` launchd job (`com.m13v.fazm-routines`) polls every 60s, finds due rows in the user's `cron_jobs` table, and spawns the headless ACP runner (`acp-bridge/src/cron-runner.mjs`) for each. The runner spawns the same ACP bridge that the floating bar uses, sends warmup + query, captures the result + cost, and writes back to `cron_jobs`/`cron_runs` plus a `chat_messages` row under `taskId="routine-<id>"` so the conversation appears in chat history.

The agent manages routines via dedicated MCP tools: `routines_create`, `routines_list`, `routines_update`, `routines_remove`, `routines_runs`. Users describe routines in natural language ("every weekday at 9am, check my emails") and the agent translates to a schedule string.

**Schedule formats:** `cron:0 9 * * 1-5`, `every:1800` (seconds), `at:2026-04-30T18:00:00Z`.

**Storage:**
- DB tables: `cron_jobs` (definitions) and `cron_runs` (execution history) in each user's `~/Library/Application Support/Fazm/users/<UUID>/fazm.db` (added in `fazmV7` migration).
- Run output is also persisted as `chat_messages` rows under `taskId='routine-<job-id>'` so the result threads into normal conversation history.

**Logs (where to investigate when something goes wrong):**
- `~/fazm/inbox/skill/logs/routines.log` — pipeline log: every spawn, every error, the high-level "Spawned N routines" tally.
- `~/fazm/inbox/skill/logs/routines-launchd-stdout.log` / `routines-launchd-stderr.log` — raw launchd capture.
- `~/fazm/inbox/skill/logs/routine-run-<short-id>-<timestamp>.log` — full per-run output, one file per fire (includes ACP bridge stderr, runner stderr, and final exit code).

**Check status / install:**
```bash
~/fazm/inbox/skill/install-routines-pipeline.sh status     # is the launchd job loaded?
~/fazm/inbox/skill/install-routines-pipeline.sh install    # install + load
~/fazm/inbox/skill/install-routines-pipeline.sh uninstall  # remove
```

**Common queries when debugging routines:**
```sql
-- All routines
SELECT id, name, schedule, enabled, last_status, last_error,
       datetime(last_run_at, 'unixepoch', 'localtime')  AS last_run,
       datetime(next_run_at, 'unixepoch', 'localtime')  AS next_run,
       run_count
FROM cron_jobs ORDER BY enabled DESC, next_run_at ASC;

-- Recent runs (most-recent first)
SELECT job_id, status,
       datetime(started_at, 'unixepoch', 'localtime') AS started,
       duration_ms, cost_usd,
       substr(COALESCE(output_text, error_message, ''), 1, 200) AS preview
FROM cron_runs ORDER BY started_at DESC LIMIT 20;

-- Force a routine to fire on the next 60s tick
UPDATE cron_jobs SET next_run_at = strftime('%s','now') WHERE id = '<job-id>';
```

When a user asks "what's wrong with my morning email routine":
1. `SELECT * FROM cron_jobs WHERE name LIKE '%email%'` to find the job + last_error.
2. `SELECT * FROM cron_runs WHERE job_id = '<id>' ORDER BY started_at DESC LIMIT 5` to see recent run outcomes.
3. `tail -200 ~/fazm/inbox/skill/logs/routines.log` for pipeline-level issues.
4. `cat ~/fazm/inbox/skill/logs/routine-run-<short-id>-*.log | tail -200` for the most recent specific run.

## Session Recording
See `scripts/SESSION-RECORDING.md` for full guide — toggle per-user recording, view chunks, architecture.

## Logs & Debugging

**When investigating a user-reported bug**, always start by pulling their Sentry + PostHog logs (`user-logs` skill or `user-issue-triage` skill) before reading code.

### Local App Logs
- **App log file**: `/private/tmp/fazm-dev.log` (dev builds) or `/private/tmp/fazm.log` (production)

### Debug Triggers (running app)

**Targeting one build (dev OR prod) when both are running**

Every debug notification is registered under TWO names:

| Form | Notification name | Who responds |
|------|-------------------|--------------|
| **Legacy (broadcast)** | `com.fazm.<suffix>` (e.g. `com.fazm.testQuery`) | Every running Fazm build (dev + prod) |
| **Bundle-scoped** | `com.fazm.<bundleID-suffix>.<suffix>` (e.g. `com.fazm.desktop-dev.testQuery`, `com.fazm.app.testQuery`) | That specific build only |

When dev (`Fazm Dev.app`, bundle ID `com.fazm.desktop-dev`) and prod (`Fazm.app`, bundle ID `com.fazm.app`) are both running, the legacy name wakes BOTH. Use the bundle-scoped form to target one build.

Replay the post-onboarding tutorial:
```bash
# Both builds (legacy):
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.replayTutorial"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'

# Dev only:
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.desktop-dev.replayTutorial"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
```

Send a text query to the floating bar (no voice/UI needed). Use the dev-scoped name if both builds are running:
```bash
# Dev only (recommended while developing):
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.desktop-dev.testQuery"), object: nil, userInfo: ["text": "your query here"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'

# Both builds (legacy):
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "your query here"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
```

Run the full tutorial programmatically (skips overlay, auto-sends all 3 steps). See `test-tutorial` skill for details:
```bash
# Dev only:
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.desktop-dev.testTutorial"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
```

The other scoped notification names follow the same `com.fazm.<bundleID-suffix>.<event>` shape: `testAnalysisOverlay`, `testAnalyzeNow`, `testClaudeAuth`, `testPaywall`, `testSessionRecordingPermission`, `testUpdateAvailable`, `founderChat`, `routinesChanged`, `control`.

### Programmatic Control (com.fazm.control)

Full programmatic control of the floating bar, replacing the need for macOS accessibility/MCP automation. Send a `com.fazm.control` distributed notification (or `com.fazm.desktop-dev.control` / `com.fazm.app.control` to target one build) with `["command": "<cmd>"]` in userInfo.

**Get state** (writes JSON to `/tmp/fazm-control-state.json` AND a bundle-scoped copy at `/tmp/fazm-control-state-<scope>.json`):
```bash
# Dev only:
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.desktop-dev.control"), object: nil, userInfo: ["command": "getState"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
cat /tmp/fazm-control-state-desktop-dev.json

# Prod only:
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.app.control"), object: nil, userInfo: ["command": "getState"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
cat /tmp/fazm-control-state-app.json
```
When both builds are running, ALWAYS read the bundle-scoped output file (`-desktop-dev.json` or `-app.json`); the legacy `/tmp/fazm-control-state.json` is last-writer-wins.

**Supported commands:**
| Command | Description |
|---------|-------------|
| `getState` | Writes full state JSON to `/tmp/fazm-control-state.json` AND `/tmp/fazm-control-state-<scope>.json` (e.g. `-desktop-dev.json`). Read the scoped file when both builds are running. |
| `newChat` | Starts a new chat session |
| `popOut` | Pops conversation out to a detached window |
| `setModel:<id>` | Sets AI model (e.g. `setModel:claude-sonnet-4-6` or `setModel:claude-opus-4-6`) |
| `toggleVoice` | Toggles voice response (TTS) on/off |
| `setVoice:on` / `setVoice:off` | Explicitly sets voice response |
| `setBrowserMode:extension` / `setBrowserMode:managed` / `setBrowserMode:off` | Sets browser automation mode. `extension` = user's real Chrome via Playwright extension; `managed` = Fazm's bundled browser-harness driving its own Chrome; `off` = no browser MCP registered (pair with `assrtEnabled` for an Assrt-only browsing surface). Auto-restarts the ACP bridge so `FAZM_BROWSER_MODE` takes effect on the next query. |
| `show` / `hide` / `toggle` | Controls floating bar visibility |
| `openInput` | Opens the AI input field |
| `sendFollowUp:<text>` | Sends a follow-up message in active conversation |
| `setWorkspace:<path>` | Sets the working directory |
| `restartBridge` | **Graceful** restart: sends SIGHUP to the running ACP bridge subprocess. The bridge waits for every in-flight query to finish, then exits, and ChatProvider relaunches it with fresh env on the next query. Use when you've changed an env var (e.g. `FAZM_BROWSER_MODE`, `ASSRT_ENABLED`) and need the bridge to pick it up. **Safe to call from inside an active chat** — the bridge defers exit until the calling agent's turn (including the `tool_use` that triggered the restart) completes, so the in-flight `tool_use_id` always gets a `tool_result`. Pre-2026-05-20 this was an immediate SIGTERM and self-bricked any session that invoked it; see the SIGHUP handler in `acp-bridge/src/index.ts` for full context. Note: the new env will only be live for **subsequent** prompts, not the agent turn that issued the restart. |
| `connectClaude` | Mirrors tapping the "Claude — Connect…" entry in the model picker. Opens the cached OAuth URL when one exists, otherwise restarts the ACP bridge to trigger a fresh `auth_required` event (which auto-opens the URL in Chrome). |
| `disconnectClaude` | Test hook that drops Claude into the unconnected state so callers can verify the "— Connect…" affordance, error messaging, and re-OAuth path. **Disruptive**: deletes `~/Library/Application Support/Claude/config.json` `oauth:tokenCache` and the `Claude Code-credentials` keychain entry (shared with Claude Desktop / CLI), then switches the bridge to builtin mode. Reversible via `connectClaude` or Settings → Reconnect. |
| `simulateCreditExhausted` / `clearCreditExhausted` | Flip `chatProvider.showCreditExhaustedAlert` to drive the post-cap UI without actually spending $10. |
| `openConnectPersonalSheet` | Open `PersonalAccountChooserSheet` directly (Claude/Codex/Gemini chooser used by Settings + credit-exhausted path). |

State JSON includes: `model`, `modelLabel`, `voiceEnabled`, `browserMode`, `workspace`, `isVisible`, `showingAIConversation`, `showingAIResponse`, `isAILoading`, `isVoiceListening`, `chatHistoryCount`, `displayedQuery`, `queueCount`, `isTutorialActive`, `isClaudeConnected`, `isClaudeAuthRequired`, `codexAuthMode`, `availableModels`, `pickerOptions` (computed labels with "— Connect…" suffix applied — same string the SwiftUI menu renders), and optionally `currentMessagePreview`/`isStreaming`.

### SQLite Database & Active User
Prod and dev now write to **separate** parent directories so neither build's data-migration logic can ever touch the other's user dirs:

- **Prod (`com.fazm.app`)**: `~/Library/Application Support/Fazm/users/<UID>/fazm.db`
- **Dev (`com.fazm.desktop-dev`)**: `~/Library/Application Support/Fazm-Dev/users/<UID>/fazm.db`

The split is done via `AppPaths.supportRoot` in `Desktop/Sources/Extensions/AppPaths.swift` (any unknown bundle ID falls back to `Fazm/` for safety).

To find the active user for the currently running build:

```bash
defaults read com.fazm.desktop-dev auth_tokenUserId  # dev build (Fazm Dev)
defaults read com.fazm.app auth_tokenUserId          # prod build (Fazm)
```

These return different Firebase UIDs even for the same Apple ID — dev and prod create separate user records. Always use this before querying or polling any SQLite DB; never guess by timestamp.

External scripts (inbox pipelines, routines, cron-runner) that hardcode `~/Library/Application Support/Fazm/users/<UID>/fazm.db` continue to target prod data, which is the intended behavior.

### Release Health (Sentry)
Check errors in the latest (or specific) release using the **sentry-release skill**:
```bash
./scripts/sentry-release.sh              # new issues in latest version (default)
./scripts/sentry-release.sh --version X  # specific version
./scripts/sentry-release.sh --all        # include carryover issues
./scripts/sentry-release.sh --quota      # billing/quota status
```
See `.claude/skills/sentry-release/SKILL.md` for full documentation.

### User Issue Investigation
When debugging issues for a specific user (crashes, errors, behavior), use the **user-logs skill**:
```bash
# Sentry (crashes, errors, breadcrumbs)
./scripts/sentry-logs.sh <email>

# PostHog (events, feature usage, app version)
./scripts/posthog_query.py <email>
```
See `.claude/skills/user-logs/SKILL.md` for full documentation and API queries.

## Testing on a Clean Mac
A MacStadium Mac mini (no Xcode, no Homebrew, no Node) is available for testing what real users experience. Use the `macstadium` skill when reproducing user-reported bugs, validating onboarding/first-run flows, or checking that a release works on a fresh machine. The `macos-use-remote` MCP provides GUI automation on it.

## Release Pipeline

### Desktop App (Codemagic)

Push a `v*-macos` tag to trigger a release:
```bash
git tag v0.2.4+16-macos && git push origin v0.2.4+16-macos
```

**Codemagic** (`codemagic.yaml`, workflow `fazm-desktop-release`) — runs on Mac mini M2:
   - Builds universal binary (arm64 + x86_64)
   - Signs with Developer ID, notarizes with Apple
   - Creates DMG + Sparkle ZIP
   - Publishes GitHub release
**Sparkle auto-update** delivers the new version to users.

### Rust Backend (GitHub Actions)

Pushing `Backend/**` changes to `main` auto-deploys to Cloud Run via `.github/workflows/deploy-backend.yml`.
Uses Workload Identity Federation (no stored keys) → `github-actions-deploy@fazm-prod.iam.gserviceaccount.com`.

**Codemagic CLI & API:**
- Token: `$CODEMAGIC_API_TOKEN` (set in `~/.zshrc`)
- App ID: `69a8b2c779d9075efc609b8d`
- List builds: `curl -s -H "x-auth-token: $CODEMAGIC_API_TOKEN" "https://api.codemagic.io/builds?appId=69a8b2c779d9075efc609b8d" | python3 -c "import json,sys; [print(f\"{b.get('status','?'):12} tag={b.get('tag','-'):30} start={(b.get('startedAt') or '-')[:19]}\") for b in json.load(sys.stdin).get('builds',[])[:5]]"`

To promote: `./scripts/promote_release.sh <tag>` (staging → beta → stable). **Never promote without explicit user approval** — releasing to staging, beta, and stable are separate decisions.

**Runtime env vars (`.env.app`):**
- Local: edit `.env.app` (gitignored, contains secrets)
- CI/CD: the `FAZM_APP_ENV` secret in Codemagic's `fazm_secrets` group holds the base64-encoded `.env.app`
- **When adding/changing env vars in `.env.app`, you MUST also update `FAZM_APP_ENV` in Codemagic** (UI Settings → Environment variables → `fazm_secrets`, or `POST https://api.codemagic.io/apps/$APP_ID/variables` with `"group":"fazm_secrets"`).
- Generate the base64 value: `cat .env.app | base64`
- The build will fail if required Vertex vars are missing (verified in codemagic.yaml)

## Bundled Skills Pipeline

Bundled skills live in `Desktop/Sources/Resources/BundledSkills/` as `{name}.skill.md` files. **This is the only place to manage them** — adding or removing a file there is all that's needed. `SkillInstaller.swift` auto-discovers them at runtime; no code change required.

Category display for onboarding is in `categoryMap` inside `SkillInstaller.swift`.

Do NOT touch `~/fazm/skills/` for bundling purposes — that directory is for publishing skills to skillhu.bz/skills.sh and is unrelated to the app bundle.

## Development Workflow

### Building & Running — ONE FLOW ONLY

**`./run.sh` is the ONLY command you ever run.** It builds everything (ACP bridge, Swift app, app bundle), copies all resources, and launches. There is ONE flow, ONE command.

**NEVER run any build command directly:**
- No `npm run build`, no `xcrun swift build`, no `swift build`, no `xcodebuild`
- No `open`, no launching from `build/`
- `run.sh` does ALL of this. Running builds independently creates stale processes, orphaned locks, and duplicate work.

**`run.sh` manages ONE lock: `/tmp/fazm-build.lock`.** It acquires it automatically on start, releases on exit. Do NOT create locks manually.

### App Names & Build Artifacts
- `./run.sh` builds **"Fazm Dev"** → installs to `/Applications/Fazm Dev.app` (bundle ID: `com.fazm.desktop-dev`)
- Production **"Fazm"** (bundle ID: `com.fazm.app`) is built by the Codemagic CI pipeline only
- To check app state: `cat /tmp/fazm-dev-status` (see "Checking App State" below)
- Legacy `com.omi.*` bundle IDs still appear in cleanup/migration code (TCC permission resets, old app bundle removal) for users who had the app when it was called Omi

### Before Running `run.sh` (Multi-Agent Safety)

Multiple agents work on this codebase simultaneously. `run.sh` handles locking automatically; it will wait if another build is active, and detects stale locks from dead processes.

- **Just run `./run.sh`**; it handles everything. If another agent holds the lock, it waits (up to 5 min).
- **NEVER manually delete `/tmp/fazm-build.lock`** or run `rm -rf /tmp/fazm-build.lock`. The lock is a directory managed by the scripts. Manually deleting it defeats the entire concurrency system and causes parallel builds to collide.
- **NEVER kill the app (`pkill -f "Fazm Dev"`) before building.** `run.sh` handles stopping the old app as part of its flow. Killing it externally orphans the lock.
- **If you only need to test with distributed notifications** (e.g., `com.fazm.testQuery`) and the app is already running, you do NOT need to run `run.sh`. Just send the notification.

### Checking App State (MANDATORY before any build/test decision)

**Always read `/tmp/fazm-dev-status` first.** This is the single source of truth for the app lifecycle. Do NOT guess state from `pgrep`, `ps aux`, or log tailing.

```bash
cat /tmp/fazm-dev-status
```

The file contains one line in the format `<state> <pid> <unix_timestamp>`:
- `building <run.sh_pid> <ts>` = build in progress, wait for it
- `running <app_pid> <ts>` = app is running, verify with `kill -0 <app_pid>`
- `exited <app_pid> <ts>` = app exited, safe to run `./run.sh`
- `failed <ts> <reason>` = last build/launch failed

**Decision tree:**
1. Read `/tmp/fazm-dev-status`
2. If `running <pid>`: check `kill -0 <pid> 2>/dev/null`. If alive, the app is running; send test notifications directly. If dead, the status is stale; safe to run `./run.sh`.
3. If `building <pid>`: check `kill -0 <pid> 2>/dev/null`. If alive, wait. If dead, stale; safe to run `./run.sh`.
4. If `exited` or `failed` or file missing: safe to run `./run.sh`.

**NEVER** use `pgrep`, `ps aux | grep`, or log file checks to determine whether to build/kill/restart. Use the status file.

### Monitoring `run.sh`

The watchdog holds the lock as long as the app process is alive (checked every 10s via the app PID). It only releases the lock and exits when the app process dies. The log file (`/private/tmp/fazm-dev.log`) is append-only; it is never truncated between runs.

If `run.sh` itself appears stalled (e.g., `swift-build` at 0% CPU for >10 minutes), first check if the holder PID is alive:
```bash
cat /tmp/fazm-build.lock/pid && cat /tmp/fazm-build.lock/script
# Then check: ps -p <pid>
```
Only if the holder process is confirmed dead AND the stale-lock detection hasn't cleaned it up, escalate to the user. Do NOT manually delete the lock.

### After Implementing Changes
- **ALWAYS test your changes** — see global CLAUDE.md "After Implementing Changes — MANDATORY Testing" for the full workflow
- **UI/visual changes**: run `./run.sh`, then use macOS automation (MCP macos-use) to navigate to the relevant screen and screenshot to verify
- **Logic/backend changes**: use programmatic test hooks (distributed notifications, etc.) to trigger and verify
- Use the `test-local` skill for the build → run → test → iterate workflow
- See `.claude/skills/test-local/SKILL.md` for details

### Changelog Entries

After completing a desktop task with user-visible impact, append a one-liner to `unreleased` in `desktop/CHANGELOG.json`:

```python
python3 -c "
import json
with open('CHANGELOG.json', 'r') as f:
    data = json.load(f)
data.setdefault('unreleased', []).append('Your user-facing change description')
with open('CHANGELOG.json', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
```

Guidelines:
- Write from the user's perspective: "Fixed X", "Added Y", "Improved Z"
- One sentence, no period at the end
- Skip internal-only changes (refactors, CI config, code cleanup)
- HTML is allowed for links: `<a href='...'>text</a>`
- Commit CHANGELOG.json with your other changes (same commit is fine)

