# test-release: Smoke Test a Fazm Release

Smoke test a Fazm release. Use when the user says "test the release", "smoke test", or "verify the build works".

**This skill does NOT build anything.** It tests the shipped product via Sparkle auto-update.

## Channel → Machine Mapping

Both the local production app (`/Applications/Fazm.app`) and the MacStadium remote are on the `staging` channel. Staging releases get tested on **both** machines; the primary test is the **local** machine (more reliable, no rate limits), with the remote as secondary.

| Channel | Test machines | `update_channel` | Sparkle sees |
|---------|-------------|-------------------|-------------|
| **staging** | Local + MacStadium remote | `staging` | staging + beta |
| **beta** | Local + MacStadium remote | `staging` (sees beta too) | beta |
| **stable** | Both | — | all |

**NEVER change either machine's `update_channel`.** Both must stay `staging`.

**NEVER promote to the next channel yourself.** Each promotion (staging→beta→stable) requires explicit user approval. Only test the channel that was just promoted.

## Prerequisites

- The release must be registered in Firestore on the channel being tested
- Local: production Fazm app installed at `/Applications/Fazm.app`
- Remote: MacStadium machine reachable (`./scripts/macstadium/ssh.sh`)

## Test Queries

Send each query via distributed notification. Wait 15 seconds between queries. After each, check logs for errors.

```bash
# Query 1: Basic chat
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "What is 2+2?"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'

# Query 2: Memory recall
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "What do you remember about me?"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'

# Query 3: Tool use / Google Workspace
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "What events do I have on my calendar today?"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'

# Query 4: File system
xcrun swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.fazm.testQuery"), object: nil, userInfo: ["text": "List the files on my Desktop"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))'
```

For remote queries, wrap in: `./scripts/macstadium/ssh.sh "xcrun swift -e '...'"` (escape inner quotes).

After each query:
- Errors: `grep -i "error\|fail\|crash\|unauthorized\|401" /private/tmp/fazm.log | tail -5`
- Response: `grep -i "Prompt completed\|Chat response complete" /private/tmp/fazm.log | tail -5`

## Flow: Staging Test — Local (PRIMARY, do this first)

1. Verify local channel: `defaults read com.fazm.app update_channel` — must be `staging`
2. Ensure production app is running: `pgrep -la Fazm` (launch with `open -a "Fazm"` if needed)
3. Reset Sparkle check time so it checks immediately: `defaults delete com.fazm.app SULastCheckTime`
4. Use `macos-use` MCP to open Fazm, navigate to Settings > About, click **"Check for Updates"**
5. Sparkle shows the update dialog — verify the correct version. **Do NOT check "Automatically download and install updates"**
6. Click **"Install Update"** (Sparkle downloads the ZIP, then shows "Ready to install")
7. Click **"Install and Relaunch"** — Sparkle waits for the app to quit before swapping the binary
8. If the app doesn't quit on its own within 10s, kill it: `pkill -x Fazm` (Sparkle needs the process gone to replace the binary)
9. Wait 10–15s, then verify the new version: `defaults read /Applications/Fazm.app/Contents/Info.plist CFBundleShortVersionString`
10. Relaunch if needed: `open -a "Fazm"`
11. Send 4 test queries locally, check `/private/tmp/fazm.log` after each
12. Check Sentry: `./scripts/sentry-release.sh --version X.Y.Z`

## Flow: Staging Test — Remote (SECONDARY)

The remote uses SSH + Sparkle's silent auto-install (no GUI clicks needed). The remote machine's Claude account frequently hits rate limits — if queries fail with "You've hit your limit", note as **blocked (rate limit)** and move on; it's not an app bug.

1. Verify remote channel: `./scripts/macstadium/ssh.sh "defaults read com.fazm.app update_channel"` — must be `staging`
2. Reset Sparkle check time: `./scripts/macstadium/ssh.sh "defaults delete com.fazm.app SULastCheckTime 2>/dev/null; echo done"`
3. Kill and relaunch Fazm to trigger the auto-check: `./scripts/macstadium/ssh.sh "pkill -x Fazm; sleep 3; open /Applications/Fazm.app"`
4. Wait 15s, check the log for `Sparkle: Found update vX.Y.Z` and `Sparkle: Installer launched`: `./scripts/macstadium/ssh.sh "grep -i 'Sparkle' /private/tmp/fazm.log | tail -10"`
5. Kill the old Fazm process so Sparkle can swap the binary: `./scripts/macstadium/ssh.sh "pkill -x Fazm"`
6. Wait 15s, then verify the new version: `./scripts/macstadium/ssh.sh "defaults read /Applications/Fazm.app/Contents/Info.plist CFBundleShortVersionString"`
7. Launch: `./scripts/macstadium/ssh.sh "open /Applications/Fazm.app; sleep 5; pgrep -la Fazm"`
8. Send 4 test queries via SSH, check remote logs after each (see "Test Queries" section for SSH wrapping)

## Report Results

| Test | Machine | Result |
|------|---------|--------|
| App updated to vX.Y.Z | local/remote | pass/fail |
| Basic chat ("2+2") | local/remote | pass/fail |
| Memory recall | local/remote | pass/fail |
| Tool use (calendar) | local/remote | pass/fail |
| File system (Desktop) | local/remote | pass/fail |
| Sentry errors | — | 0 new / N new |

**pass** = AI responded without errors in logs
**fail** = no response, error in logs, or crash

## What Counts as a Failure

- **Sparkle update fails** — hard failure. Do NOT work around with manual ZIP install. Common cause: broken code signature from `__pycache__` files written inside the app bundle.
- App doesn't update (Sparkle error, appcast not serving correct version)
- Query gets no AI response within 60 seconds
- Logs show `error`, `crash`, `unauthorized`, `401`, or `failed` during the query
- App crashes or becomes unresponsive
- Sentry shows new issues for this release version
