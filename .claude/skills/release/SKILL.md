---
name: release
description: Use when the user says "release", "cut a release", "ship a new version", "release new version", "do the desktop release", or "tag a release". Computes the next version, generates the changelog, pushes a `v*-macos` tag, and monitors the Codemagic CI build that produces and publishes the macOS desktop release. NEVER builds locally.
allowed-tools: Bash, Read, Edit, Grep
---

# Fazm Desktop Release Skill (Codemagic-only)

Cut a new Fazm Desktop release. **All builds run in Codemagic CI** triggered by a `v*-macos` git tag. There is no local build path.

## CRITICAL RULES

1. **NEVER build the .app locally for a release.** No `xcodebuild`, no `xcrun swift build`, no shell wrapper that produces release artifacts. The local build path (`release.sh`) was deleted on purpose 2026-05-02. It silently stripped overlay assets and shipped two broken versions (v2.7.0 and v2.7.1) without `browser-overlay-init.js` because it lacked the codemagic.yaml hard-check. Codemagic has stricter checks; use it.
2. **NEVER push the same `v*-macos` tag twice.** Each Codemagic build generates a fresh EdDSA signature for the Sparkle ZIP. Re-pushing the tag (or re-running the build) produces a new ZIP with a different signature while the OLD ZIP can still be cached on the appcast — Sparkle then refuses the update with "improperly signed" for every user. If you need to retry, **bump to the next patch version** (e.g. `v2.7.2+2007002-macos`).
3. **NEVER edit `codemagic.yaml` mid-release.** If a step fails, root-cause first; do not patch CI to silence it. Once you know the fix, land it on `main`, bump version, push a fresh tag.
4. **NEVER skip the changelog step.** Codemagic's "Prepare changelog" step commits the consolidated CHANGELOG.json back to `main`; if `unreleased` is empty, the GitHub release notes will be empty too.
5. **Do not promote to beta or stable without explicit user approval.** Each promotion (staging → beta → stable) is a separate user decision.

## How a release works (architecture)

```
git tag v$VERSION+$BUILD-macos   →   git push origin <tag>   →   Codemagic triggers
                                                                  ↓
                                build · sign · notarize · staple · DMG · Sparkle ZIP
                                                                  ↓
                                       gh release create  +  Firestore register
                                                                  ↓
                                              appcast.xml deploy  →  users update
```

- **Codemagic project**: `fazm-desktop-release` (workflow defined in `codemagic.yaml`)
- **App ID**: `69a8b2c779d9075efc609b8d`
- **API token**: `$CODEMAGIC_API_TOKEN` (set in `~/.zshrc`)
- **Triggering tag patterns**: `v*-macos` (production) and `v*-macos-staging` (pre-release)
- **Final artifacts**: `Fazm.zip` (Sparkle auto-update), `Fazm.dmg` (manual install), arch-specific zips on GCS, stub installer DMG

The full pipeline (in order, defined in `codemagic.yaml`):
1. Extract version + build number from tag
2. Set up keychain + Developer ID
3. Build acp-bridge (TypeScript → JS, runs `npm install` which triggers `patch-playwright-overlay.cjs` postinstall)
4. Prepare universal ffmpeg / Node / cloudflared (arm64 + x86_64)
5. Resolve SPM packages
6. Build mcp-server-macos-use, whatsapp-mcp (both arm64 + x86_64)
7. Clone Google Workspace MCP
8. Build Swift app (universal binary)
9. Create universal app bundle — **includes the overlay file copy AND the `_fazmOverlayScript` hard-check**
10. Sign app (Developer ID, all native binaries in node_modules)
11. Notarize, staple
12. Create arch-specific zips for stub installer
13. Upload dSYMs to Sentry
14. Create + sign + notarize + staple DMG
15. Create Sparkle ZIP + EdDSA sign
16. Prepare changelog (consolidates `unreleased` → versioned, commits back to main)
17. Create GitHub release (uploads `Fazm.zip` and `Fazm.dmg`)
18. Register release in Firestore (channel = `staging` initially)
19. Deploy appcast.xml
20. Upload arch-specific zips to GCS
21. Build + upload stub installer

## Pre-release checklist (run locally BEFORE pushing the tag)

```bash
# 1) Verify settings search coverage
xcrun swift scripts/check_settings_search.swift

# 2) Verify changelog has unreleased entries
python3 -c "
import json
data = json.load(open('CHANGELOG.json'))
entries = data.get('unreleased', [])
if not entries:
    print('FATAL: unreleased is empty — add entries before tagging'); exit(1)
print('\n'.join(entries))
"

# 3) Working tree must be clean and on main
git status --porcelain   # must be empty
git rev-parse --abbrev-ref HEAD   # must be 'main'

# 4) Sanity-check the bridge builds locally (catches TS errors before CI)
cd acp-bridge && PATH=/opt/homebrew/bin:$PATH npm install --no-audit --no-fund && npm run build && cd ..

# 5) Verify the playwright overlay patch still applies cleanly
grep -q "_fazmOverlayScript" acp-bridge/node_modules/playwright-core/lib/coreBundle.js \
  || { echo "FATAL: overlay patch did not apply locally — Codemagic will fail too"; exit 1; }
```

If any check fails, **fix it on `main` first**. Tagging a broken commit wastes ~20 min of CI time.

## Cutting the release

### Step 1: Compute next version

Versions are `MAJOR.MINOR.PATCH+BUILD`. Build number is monotonically increasing; the convention has been `MMmmppp + 2000000` (e.g. v2.7.1 → build `2007001`).

```bash
LAST_TAG=$(git tag -l 'v*-macos' | grep -v staging | sort -V | tail -1)
echo "Last release tag: $LAST_TAG"
# Auto patch bump: 2.7.1 → 2.7.2, 2007001 → 2007002 → tag v2.7.2+2007002-macos
# For minor/major bumps, ask the user.
```

### Step 2: Push the tag

```bash
TAG="v${VERSION}+${BUILD}-macos"
git tag "$TAG"
git push origin "$TAG"
```

That single push triggers Codemagic. Do **not** push to `main` separately for the release; Codemagic itself commits the consolidated changelog back during the build.

### Step 3: Monitor the build

```bash
TOKEN=$CODEMAGIC_API_TOKEN
APP_ID=69a8b2c779d9075efc609b8d
TAG="v${VERSION}+${BUILD}-macos"

# Wait briefly for Codemagic to register the tag, then locate the build
sleep 30
BUILD_ID=$(curl -s -H "x-auth-token: $TOKEN" \
  "https://api.codemagic.io/builds?appId=$APP_ID&limit=10" | \
  python3 -c "
import json, sys
for b in json.load(sys.stdin).get('builds', []):
    if b.get('tag') == '$TAG':
        print(b['_id']); break
")
echo "Build: $BUILD_ID"

# Poll status (build takes ~20-30 min)
while true; do
  STATUS=$(curl -s -H "x-auth-token: $TOKEN" \
    "https://api.codemagic.io/builds/$BUILD_ID" | \
    python3 -c "import json, sys; print(json.load(sys.stdin)['build']['status'])")
  echo "$(date +%T) status=$STATUS"
  case "$STATUS" in
    finished) echo "✓ Build succeeded"; break ;;
    failed|canceled) echo "✗ Build $STATUS — fetch logs via the codemagic skill"; break ;;
  esac
  sleep 30
done
```

If a step fails, fetch the per-step log via the `codemagic` skill and root-cause it. **Do not retry the same tag**; bump to the next patch version after the fix lands.

### Step 4: Verify the release

```bash
./verify-release.sh "$VERSION"
```

This script automatically:
- Checks the appcast serves the correct version
- Downloads `Fazm.zip` (what auto-updaters get) and verifies signature, notarization, Gatekeeper acceptance
- Launches the app and confirms it starts
- Checks the DMG download endpoint

If verification fails, **immediately roll back** with the `rollback` skill (`.claude/skills/rollback/SKILL.md`) — do **not** try to "fix the live release" by pushing another tag.

### Step 5: Smoke-test on staging

A fresh release lands on the `staging` channel. Run `/test-release` on the **remote MacStadium machine** (staging channel only). See `.claude/skills/test-release/SKILL.md`.

Report results. **Wait for explicit user approval** before promoting.

### Step 6: Promote (only when user explicitly says so)

```bash
./scripts/promote_release.sh "$TAG"           # staging → beta
# After user approves again:
./scripts/promote_release.sh "$TAG" --stable  # beta → stable
```

Each promotion is a separate user decision. Re-test on the appropriate machine after each.

## Failure handling

### Codemagic step fails
1. Identify the failing step from the build log (use the `codemagic` skill)
2. Land the fix on `main`
3. Bump to the next patch version (do **not** re-push the same tag)
4. Push the new tag

### Notarization fails (unsigned binary)
- Check the notarytool log for the unsigned path
- Add a `codesign --force --options runtime --timestamp $CS_PAGESIZE --sign "$SIGN_IDENTITY" "$path"` line to the "Sign app" step in `codemagic.yaml`
- Land it, bump version, retag

### Stapling fails (Apple CDN propagation)
- Common transient. Bump to the next patch version and retry. The build is fast on cache hit; notarization is usually quick the second time.

### Hard-check fails (`overlay asset … missing` or `coreBundle.js NOT patched`)
- The patch script `acp-bridge/scripts/patch-playwright-overlay.cjs` did not match the current Playwright MCP shape (see commit `4584c94f` for the most recent successful update)
- Fix the OLD_BLOCK / NEW_BLOCK in the patch script to match the new shape
- Land the fix, bump version, retag
- Do **not** set `FAZM_ALLOW_MISSING_OVERLAY=1` in CI just to ship — that ships a broken indicator

### "Improperly signed" reported by users after release
- Means the same tag was built twice with different EdDSA signatures, or the Sparkle ZIP on GitHub does not match the signature in the appcast
- **Do not retag.** Bump to the next patch version and push a fresh release. The new appcast entry will carry the new ZIP and matching signature.

## After a release ships

- Append a changelog entry to `unreleased` in `CHANGELOG.json` for any subsequent user-visible change. The next release rolls those into its versioned entry automatically.
- Use `./scripts/sentry-release.sh` to monitor crash health on the new version (see the `sentry-release` skill).

## What was deleted and why

- **`release.sh`** (root) — local build pipeline. Deleted 2026-05-02. It had no overlay-asset copy step and no hard check, so it shipped v2.7.0 and v2.7.1 missing `browser-overlay-init.js`, silently breaking the "Browser controlled by Fazm" indicator. Codemagic has full feature parity (and stricter checks). Local builds are forbidden for release artifacts; use `./run.sh` only for dev iteration on `Fazm Dev.app`.
- **`Bash(./release.sh:*)`** in `.claude/settings.local.json` — removed at the same time so agents can't accidentally invoke a path that no longer exists.

## Key files

- **CI workflow**: `codemagic.yaml`
- **Verification**: `verify-release.sh`
- **Promotion**: `scripts/promote_release.sh`
- **Changelog**: `CHANGELOG.json`
- **Overlay patch**: `acp-bridge/scripts/patch-playwright-overlay.cjs` (postinstall, must match current `@playwright/mcp` shape)
- **Rollback skill**: `.claude/skills/rollback/SKILL.md`
- **Codemagic skill**: `.claude/skills/codemagic/SKILL.md`
- **Test skill**: `.claude/skills/test-release/SKILL.md`
