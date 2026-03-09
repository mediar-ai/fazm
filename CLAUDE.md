# Claude Project Context

## Project Overview
Fazm — a macOS desktop app (Swift). Open source at github.com/m13v/fazm.

## Logs & Debugging

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

Do NOT touch `~/fazm/skills/` for bundling purposes — that directory is for publishing GWS skills to skillhu.bz/skills.sh and is unrelated to the app bundle.

## Development Workflow

### Building & Running
- **No Xcode project** — this is a Swift Package Manager project
- **Build command**: `xcrun swift build -c debug --package-path Desktop` (the `xcrun` prefix is required to match the SDK version)
- **Full dev run**: `./run.sh` — builds Swift app, starts Rust backend, starts Cloudflare tunnel, launches app
- **Build only**: `./build.sh` — release build without running
- **DO NOT** use bare `swift build` — it will fail with SDK version mismatch
- **DO NOT** use `xcodebuild` — there is no `.xcodeproj`
- **DO NOT** launch the app directly from `build/` — always use `./run.sh` or `./reset-and-run.sh`. These scripts install to `/Applications/Fazm Dev.app` and launch from there, which is required for macOS "Quit & Reopen" (after granting permissions) to find the correct binary. Launching from `build/` causes stale binaries to run after permission restarts.
- **DO NOT** manually copy binaries into app bundles and launch them — this bypasses signing, `/Applications/` installation, and LaunchServices registration

### App Names & Build Artifacts
- `./run.sh` builds **"Fazm Dev"** → installs to `/Applications/Fazm Dev.app` (bundle ID: `com.fazm.desktop-dev`)
- `./build.sh` builds **"Fazm"** → `build/Fazm.app` (bundle ID: `com.fazm.app`)
- Different bundle IDs, different app names, but same source code
- When updating resources (icons, assets, etc.) in built app bundles, update BOTH
- To check which app is currently running: `ps aux | grep "Fazm"`
- Legacy `com.omi.*` bundle IDs still appear in cleanup/migration code (TCC permission resets, old app bundle removal) for users who had the app when it was called Omi

### After Implementing Changes
- **ALWAYS test your changes** — see global CLAUDE.md "After Implementing Changes — MANDATORY Testing" for the full workflow
- **UI/visual changes**: build with `./run.sh`, then use macOS automation (MCP macos-use) to navigate to the relevant screen and screenshot to verify
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

