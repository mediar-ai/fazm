---
name: google-workspace-setup
version: 1.0.0
description: "Set up Google Workspace integration (Gmail, Calendar, Drive, Docs, Sheets). Creates a personal Google Cloud OAuth app via browser automation. Use when: 'set up google workspace', 'connect gmail', 'connect google drive', 'google workspace setup', 'OAuth client credentials not found', or any Google Workspace tool fails with auth errors."
---

# Google Workspace Setup

Set up Google Workspace integration so the user can use Gmail, Calendar, Drive, Docs, and Sheets through Fazm. This creates a personal Google Cloud OAuth app — credentials stay on the user's machine and are never shared.

## When to trigger automatically

- Any `mcp__google-workspace__*` tool returns "OAuth client credentials not found"
- User asks to read email, manage calendar, access Drive/Docs/Sheets
- User says "set up google workspace", "connect gmail", etc.

## What to tell the user

> **"To use Google Workspace (Gmail, Drive, Docs, etc.), I need to set up a one-time connection to your Google account. Here's what that means:**
>
> - **It's yours alone** — this creates a personal app in your own Google Cloud account
> - **Stays on your computer** — credentials are stored locally and never leave your machine
> - **One-time setup** — after this, Google tools work silently without prompts
> - **Takes ~5-10 minutes** — I'll automate most of it via browser. You just need to sign in once."

Wait for the user to confirm before proceeding.

## Setup Flow

Use Playwright MCP for all browser automation steps.

### Step 0: Check if already set up

```bash
cat ~/google_workspace_mcp/client_secret.json 2>/dev/null
```

If the file exists and has valid `installed.client_id`, skip to "First OAuth login" below.

### Step 1: Sign in to Google Cloud Console

Navigate to `https://console.cloud.google.com/` using Playwright.

- If not signed in, tell the user: "Please sign in to your Google account in the browser, then say 'done'"
- Verify sign-in by checking for the Console dashboard

### Step 2: Create a new Google Cloud project

Navigate to `https://console.cloud.google.com/projectcreate`

- **Project name**: Ask the user for their name, use "[Name]'s App" (e.g., "Sarah's App")
- **Organization**: For personal use, "No organization" is fine
- Click "Create" and wait, then switch to the new project

### Step 3: Enable Google Workspace APIs

Navigate to each URL and click "Enable":

```
https://console.cloud.google.com/apis/library/gmail.googleapis.com
https://console.cloud.google.com/apis/library/calendar-json.googleapis.com
https://console.cloud.google.com/apis/library/drive.googleapis.com
https://console.cloud.google.com/apis/library/docs.googleapis.com
https://console.cloud.google.com/apis/library/sheets.googleapis.com
```

### Step 4: Configure OAuth consent screen

Navigate to `https://console.cloud.google.com/auth/overview` (new Google Auth Platform).

If it redirects to the old flow at `/apis/credentials/consent`, use that instead.

#### New flow:
1. Click "Get started" if prompted
2. **App name**: "[Name]'s App"
3. **User support email**: User's email
4. **Audience**: External
5. **Contact information**: User's email
6. Save/Continue

#### Old flow (fallback):
1. Select **External** → Create
2. **App name**: "[Name]'s App", **Support email**: User's email, **Developer email**: User's email
3. "Save and Continue" through Scopes
4. **Test users**: Click "Add Users" → enter user's email → Save
5. "Save and Continue" → "Back to Dashboard"

**IMPORTANT**: The user's email MUST be added as a test user or OAuth will fail with "access_denied".

### Step 5: Create OAuth credentials

Navigate to `https://console.cloud.google.com/apis/credentials`

1. Click **"+ Create Credentials"** → **"OAuth client ID"**
2. **Application type**: **"Desktop app"**
3. **Name**: "Fazm"
4. Click **"Create"**
5. Click **"Download JSON"** to get `client_secret_*.json`

### Step 6: Install credentials

```bash
mkdir -p ~/google_workspace_mcp
mv ~/Downloads/client_secret_*.json ~/google_workspace_mcp/client_secret.json
```

**Verify**: `cat ~/google_workspace_mcp/client_secret.json` contains `installed.client_id`.

### Step 7: First OAuth login

Note: the Google Workspace MCP server only loads once `client_secret.json` exists, and the tool list is rebuilt on each new chat. If `mcp__google-workspace__*` tools are missing in this session, tell the user to start a new chat to finish this step there.

Now trigger any Google Workspace tool (e.g., `search_gmail_messages` with query "is:inbox") to initiate the OAuth flow. The MCP server will open a browser window for the user to authorize. Tell the user to complete the sign-in.

After authorization, tokens are cached at `~/google_workspace_mcp/auth/` and subsequent calls work silently.

### Step 8: Summary

```
Google Workspace Setup Complete!

  Project:    PROJECT_NAME
  Credential: ~/google_workspace_mcp/client_secret.json
  Account:    USER_EMAIL
  APIs:       Gmail, Calendar, Drive, Docs, Sheets

Google Workspace tools are now ready to use.
```

## Troubleshooting

- **"access_denied"**: User's email not added as test user in OAuth consent screen
- **"This app is blocked"**: Google sometimes blocks new apps temporarily — wait a few minutes
- **"Access blocked: request is invalid"**: OAuth consent screen not configured — redo Step 4
