# Claude Project Context

## Project Overview
Fazm — a macOS desktop app (Swift). Open source at github.com/m13v/fazm.

## Session Recording
See `scripts/SESSION-RECORDING.md` for full guide — toggle per-user recording, view chunks, architecture.

## Logs & Debugging

**When investigating a user-reported bug**, always start by pulling their Sentry + PostHog logs (`user-logs` skill or `user-issue-triage` skill) before reading code.

### Local App Logs
- **App log file**: `/private/tmp/fazm-dev.log` (dev builds) or `/private/tmp/fazm.log` (production)

### Debug Triggers (running app)
Replay the post-onboarding tutorial:
```bash
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.omi.replayTutorial"), object: nil, userInfo: nil, deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
```

Send a text query to the floating bar (no voice/UI needed):
```bash
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "your query here"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
```

### SQLite Database & Active User
Messages are stored in `~/Library/Application Support/Fazm/users/<UUID>/fazm.db` (both prod and dev share this directory). To find the active user for the currently running build:

```bash
defaults read com.fazm.desktop-dev auth_userId  # dev build (Fazm Dev)
defaults read com.fazm.app auth_userId           # prod build (Fazm)
```

These return different UUIDs even for the same Apple ID — dev and prod create separate user records. Always use this before querying or polling any SQLite DB; never guess by timestamp.

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

To promote: `./scripts/promote_release.sh <tag>` (staging → beta → stable).

**Runtime env vars (`.env.app`):**
- Local: edit `.env.app` (gitignored, contains secrets)
- CI/CD: the `FAZM_APP_ENV` secret in Codemagic's `fazm_secrets` group holds the base64-encoded `.env.app`
- **When adding/changing env vars in `.env.app`, you MUST also update `FAZM_APP_ENV` in Codemagic UI** (Settings → Environment variables → fazm_secrets). The Codemagic API cannot read/write team-level variable groups — UI only.
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
- **Build only** (no launch): `./build.sh` — for release builds only

**`run.sh` manages ONE lock: `/tmp/fazm-build.lock`.** It acquires it automatically on start, releases on exit. Do NOT create locks manually.

### App Names & Build Artifacts
- `./run.sh` builds **"Fazm Dev"** → installs to `/Applications/Fazm Dev.app` (bundle ID: `com.fazm.desktop-dev`)
- `./build.sh` builds **"Fazm"** → `build/Fazm.app` (bundle ID: `com.fazm.app`)
- Different bundle IDs, different app names, but same source code
- When updating resources (icons, assets, etc.) in built app bundles, update BOTH
- To check which app is currently running: `ps aux | grep "Fazm"`
- Legacy `com.omi.*` bundle IDs still appear in cleanup/migration code (TCC permission resets, old app bundle removal) for users who had the app when it was called Omi

### Before Running `run.sh` (Multi-Agent Safety)

Multiple agents work on this codebase simultaneously. `run.sh` handles locking automatically — it will wait if another `run.sh` is active, and detect stale locks from dead processes.

- **Just run `./run.sh`** — it handles everything. If another agent holds the lock, it waits (up to 5 min).
- **If you only need to test with distributed notifications** (e.g., `com.fazm.testQuery`) and the app is already running, you do NOT need to run `run.sh`. Just send the notification.

### Monitoring `run.sh`

After launching `run.sh`, monitor the dev log (`/private/tmp/fazm-dev.log`) to confirm progress:

```bash
# Check that run.sh is producing output — if no new logs for 60s, it's stalled
tail -1 /private/tmp/fazm-dev.log  # should show recent activity
```

If no new log lines appear for **60 seconds**, `run.sh` is stalled. Kill it and retry:
```bash
rm -rf /tmp/fazm-build.lock
pkill -f "run\.sh"; pkill -f "swift-build"
# Then run ./run.sh again
```

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

