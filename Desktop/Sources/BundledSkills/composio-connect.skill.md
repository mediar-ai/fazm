---
name: composio-connect
version: 1.0.0
description: "Use when the user says 'connect gmail', 'connect my email', 'let fazm read my inbox', 'integrate gmail', 'set up gmail', or asks Fazm to read/search their Gmail and Fazm has no Gmail tools registered. Walks the user through the Composio-hosted OAuth flow so the agent can call Gmail tools (read inbox, draft reply, label, search) over MCP."
---

# Composio Connect: Gmail (and friends)

Connect the user's Gmail (or other third-party apps in the future) so the agent gets normal Gmail tools (`composio_gmail__GMAIL_FETCH_EMAILS`, `_SEND_EMAIL`, `_CREATE_DRAFT`, etc.) registered via MCP. The OAuth flow is hosted by Composio; the user's Google credentials never touch Fazm.

## When to trigger automatically

- The user asks Fazm to read, search, summarize, draft, send, or label email and there are no `composio_gmail__*` tools in the registered tool list.
- The user says "connect gmail", "let fazm read my email", "set up email", "integrate gmail".
- A previous Gmail tool call returned an auth error like "Account not connected" or 401.

If `composio_gmail__*` tools are already visible in the tool list, skip this skill entirely and just call the tools.

## What to tell the user first

> "To read or send Gmail through Fazm, I need to connect your Google account. **You'll sign in to Google through Composio's hosted page**. Composio is a third-party integration platform; they hold the OAuth token, and Fazm calls them on your behalf. The Composio API key stays on Fazm's backend — it never ships in the app. Want to proceed?"

Wait for the user to say yes before starting the flow. If they say no, stop.

## Required environment

Before doing anything, verify the bridge has the env vars we need:

```bash
if [ -z "$FAZM_BACKEND_URL" ] || [ -z "$FAZM_AUTH_TOKEN" ]; then
  echo "Missing FAZM_BACKEND_URL or FAZM_AUTH_TOKEN — user is not signed in. Ask them to sign into Fazm first."
  exit 1
fi
```

If the check fails, tell the user "I need you to be signed into Fazm before I can connect Gmail. Please sign in from the floating bar (avatar > Sign In)." then stop.

## Step 1: Kick off the OAuth flow

Call our backend to create a Composio "connected_account" in INITIATED state and get the user-facing redirect URL.

```bash
RESP=$(curl -sS -X POST "$FAZM_BACKEND_URL/api/composio/connect" \
  -H "Authorization: Bearer $FAZM_AUTH_TOKEN" \
  -H "content-type: application/json" \
  -d '{"toolkit": "gmail"}')

echo "$RESP" | jq .
```

Expected shape:

```json
{
  "redirect_url": "https://accounts.google.com/o/oauth2/auth?...",
  "connected_account_id": "ca_xxxxx",
  "status": "INITIATED"
}
```

Parse `redirect_url` and `connected_account_id`. Store them for later steps. If the response has no `redirect_url`, surface the error to the user verbatim and stop.

## Step 2: Send the user to Google

Open the OAuth URL in the user's default browser:

```bash
open "$REDIRECT_URL"
```

Then tell the user:

> "I opened Google sign-in in your browser. Please pick the Gmail account you want Fazm to use and approve the requested scopes. Come back here once you're done."

**Do not poll aggressively.** Wait for the user to confirm with something like "done", "approved", or "ok". The Composio OAuth page does not deep-link back to Fazm; the user has to tell you.

## Step 3: Verify connection landed as ACTIVE

Once the user says they're done, poll `/api/composio/status?toolkit=gmail` until `connected=true`:

```bash
for i in 1 2 3 4 5; do
  STATUS=$(curl -sS "$FAZM_BACKEND_URL/api/composio/status?toolkit=gmail" \
    -H "Authorization: Bearer $FAZM_AUTH_TOKEN")
  CONNECTED=$(echo "$STATUS" | jq -r '.connected')
  if [ "$CONNECTED" = "true" ]; then
    echo "Gmail connected."
    break
  fi
  echo "Not yet active (attempt $i)..."
  sleep 3
done
```

If after 5 tries it is still not ACTIVE, ask the user "Did you complete the Google sign-in? If you canceled, say so and I'll restart the flow."

## Step 4: Flip the in-app flag and restart the bridge

Once verified `ACTIVE`, set the UserDefaults flag so future bridge spawns inject `FAZM_COMPOSIO_TOOLKITS=gmail`, and restart the bridge so this session picks up the new MCP server.

Resolve the bundle ID once:

```bash
BUNDLE_ID="${FAZM_BUNDLE_SCOPE:-app}"
case "$BUNDLE_ID" in
  desktop-dev) DEFAULTS_DOMAIN="com.fazm.desktop-dev"; CONTROL_NAME="com.fazm.desktop-dev.control" ;;
  *)            DEFAULTS_DOMAIN="com.fazm.app";        CONTROL_NAME="com.fazm.app.control" ;;
esac

defaults write "$DEFAULTS_DOMAIN" composioGmailEnabled -bool true

xcrun swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(\"$CONTROL_NAME\"), object: nil, userInfo: [\"command\": \"restartBridge\"], deliverImmediately: true); RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))"
```

Tell the user:

> "Gmail is connected. Restarting the agent so the new tools take effect — give me a few seconds, then ask me to check your inbox or draft a reply."

After `restartBridge`, the NEXT prompt the user sends triggers a fresh bridge with the MCP server registered. You cannot use Gmail tools in *this* turn (the bridge defers the restart until your turn ends).

## Step 5: Quick verification (optional)

After the next user message arrives in a fresh bridge, you can confirm by listing one inbox email:

```
Call composio_gmail__GMAIL_FETCH_EMAILS with { "max_results": 1, "query": "in:inbox" }
```

If it returns a message, the integration works. If it 401s, the access token expired and the user should retry the skill from Step 1.

## Disconnect

If the user later says "disconnect gmail" or "stop fazm reading my email":

```bash
# Get the connected_account_id
ACCOUNTS=$(curl -sS "$FAZM_BACKEND_URL/api/composio/status?toolkit=gmail" \
  -H "Authorization: Bearer $FAZM_AUTH_TOKEN" | jq -r '.accounts[0].id // empty')

if [ -n "$ACCOUNTS" ]; then
  curl -sS -X POST "$FAZM_BACKEND_URL/api/composio/disconnect" \
    -H "Authorization: Bearer $FAZM_AUTH_TOKEN" \
    -H "content-type: application/json" \
    -d "{\"connected_account_id\":\"$ACCOUNTS\"}"
fi

defaults write "$DEFAULTS_DOMAIN" composioGmailEnabled -bool false
# Same restartBridge swift-e call as above
```

Tell the user "Disconnected. Fazm no longer has access to your Gmail."

## Common errors and fixes

- **"Composio not configured on backend" (503)**: The `COMPOSIO_API_KEY` env var is missing on Cloud Run. Surface verbatim; the user can't fix this.
- **"No redirect_url in response"**: Composio API changed shape. Log the full body to the user, ask them to ping the Fazm team.
- **Status stays INITIATED forever**: User closed the OAuth tab without finishing. Restart from Step 1.
- **`composio_gmail__*` tools still missing after restartBridge**: Confirm `defaults read $DEFAULTS_DOMAIN composioGmailEnabled` returns `1` and the user is signed in. The bridge log shows `Composio MCP enabled: gmail → ...` when wiring succeeds; absence of that line means env vars didn't propagate.
