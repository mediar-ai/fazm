---
name: gws-setup
version: 1.0.0
description: "Create a personal Google Cloud OAuth app for the GWS CLI. Automates project creation, API enablement, OAuth consent screen, and credential generation via browser automation. Use when: 'set up gws', 'gws setup', 'create google app', 'personal google oauth', 'configure gws credentials'."
metadata:
  openclaw:
    category: "productivity"
    requires:
      bins: ["gws"]
---

# GWS Setup — Personal Google Cloud App

Interactive setup wizard that creates a personal Google Cloud OAuth app so the user can use the GWS CLI with their own credentials and quotas.

## What to expect

Before starting, set the user's expectations clearly:

> **"I'm going to set up a personal Google Cloud OAuth app for you. Here's what that means:**
>
> - **It's yours alone** — this app lives in your own Google Cloud account. You're the only user. No one else can access it.
> - **Stays on your computer** — credentials are stored locally in `~/.config/gws/` and never leave your machine.
> - **One-time setup** — you'll only need to click through the Google sign-in once. After that, all GWS commands run silently without any browser prompts.
> - **Hands-free after auth** — I'll handle all the Google Cloud Console steps automatically using browser automation. You just need to authenticate when I ask.
> - **Takes ~5–10 minutes** — feel free to keep working in other windows while I set this up in the background."

Wait for the user to confirm they're ready before proceeding.

## When to use

- First-time GWS CLI setup (no `~/.config/gws/client_secret.json` exists)
- User wants their own Google Cloud app instead of the shared/bundled one
- Replacing expired or revoked OAuth credentials
- Troubleshooting "access denied" or quota errors with the bundled client

## Prerequisites

- A Google account (any Gmail or Workspace account)
- Browser automation (Playwright MCP) for Google Cloud Console interaction
- `gws` binary on PATH or bundled in app

## Setup Flow

Run these steps in order. Use browser automation (Playwright MCP) for all Google Cloud Console interactions. Ask the user for input at each decision point.

### Step 0: Check current state

```bash
# Check if gws is installed
which gws 2>/dev/null || echo "NOT_FOUND"

# Check if credentials already exist
ls ~/.config/gws/client_secret.json 2>/dev/null && echo "HAS_CLIENT_SECRET" || echo "NO_CLIENT_SECRET"
ls ~/.config/gws/credentials.json 2>/dev/null && echo "HAS_CREDENTIALS" || echo "NO_CREDENTIALS"
```

If `HAS_CLIENT_SECRET`: tell the user they already have credentials configured and ask if they want to replace them with a personal app.

If `NOT_FOUND` for gws: tell the user to install gws first (`npm install -g @googleworkspace/cli`).

### Step 1: Sign in to Google Cloud Console

Navigate to `https://console.cloud.google.com/` using Playwright.

- Check if the user is already signed in
- If not signed in, navigate to the sign-in page and tell the user: "Please sign in to your Google account in the browser, then say 'done'"
- Verify sign-in succeeded by checking for the Console dashboard

### Step 2: Create a new Google Cloud project

Navigate to `https://console.cloud.google.com/projectcreate`

- **Project name**: Ask the user for their name, then use "[Name]'s App" (e.g., "Sarah's App"). This appears on the OAuth consent screen, so it should be instantly recognizable to the user.
- **Organization**: If the user has multiple orgs, let them pick. For personal use, "No organization" is fine
- Click "Create" and wait for the project to be created
- After creation, **switch to the new project** using the project selector if not auto-switched

**Verify**: The project name appears in the top navigation bar.

### Step 3: Enable required APIs

Navigate to the API Library and enable each API. For each one:
1. Navigate to the API page
2. Click "Enable"
3. Wait for confirmation

Enable these 6 APIs (navigate to each URL, replacing `PROJECT_ID`):

```
https://console.cloud.google.com/apis/library/gmail.googleapis.com
https://console.cloud.google.com/apis/library/calendar-json.googleapis.com
https://console.cloud.google.com/apis/library/drive.googleapis.com
https://console.cloud.google.com/apis/library/docs.googleapis.com
https://console.cloud.google.com/apis/library/sheets.googleapis.com
https://console.cloud.google.com/apis/library/keep.googleapis.com
```

**Verify**: All 6 APIs show as "Enabled" in the API dashboard.

### Step 4: Configure OAuth consent screen

Navigate to `https://console.cloud.google.com/auth/overview` (the new Google Auth Platform).

Note: Google is transitioning from the old "OAuth consent screen" to the new "Google Auth Platform". Try the new URL first; if it redirects to the old flow, follow that instead.

#### New Google Auth Platform flow:
1. Navigate to `https://console.cloud.google.com/auth/overview`
2. If prompted to "Get started" or configure branding:
   - **App name**: User's choice or "[Name]'s App" (e.g., "Sarah's App")
   - **User support email**: User's email
   - **Audience**: Select "External"
   - **Contact information**: User's email
3. Save/Continue through the setup

#### Old OAuth consent screen flow (fallback):
1. Navigate to `https://console.cloud.google.com/apis/credentials/consent`
2. Select **External** user type → Create
3. Fill in:
   - **App name**: User's choice or "[Name]'s App" (e.g., "Sarah's App")
   - **User support email**: Select from dropdown
   - **Developer contact email**: User's email
4. Click "Save and Continue"
5. **Scopes page**: Click "Save and Continue" (skip — scopes are requested at runtime by gws)
6. **Test users page**: Click "Add Users" → enter the user's email → Save
7. Click "Save and Continue" → "Back to Dashboard"

**IMPORTANT**: Add the user's own email as a test user. Without this, OAuth will fail with "access_denied".

### Step 5: Create OAuth client credentials

Navigate to `https://console.cloud.google.com/apis/credentials`

1. Click **"+ Create Credentials"** → **"OAuth client ID"**
2. **Application type**: Select **"Desktop app"**
3. **Name**: "GWS CLI" (or any name)
4. Click **"Create"**
5. A dialog appears with the Client ID and Client Secret
6. Click **"Download JSON"** to download the `client_secret_*.json` file

**Verify**: The JSON file was downloaded. It should contain `installed.client_id` and `installed.client_secret`.

### Step 6: Install the credentials

```bash
# Back up existing client_secret.json if present
if [ -f ~/.config/gws/client_secret.json ]; then
  cp ~/.config/gws/client_secret.json ~/.config/gws/client_secret.json.bak
  echo "Backed up existing credentials to client_secret.json.bak"
fi

# Create config directory
mkdir -p ~/.config/gws

# Copy downloaded file (adjust path based on where browser downloaded it)
cp ~/Downloads/client_secret_*.json ~/.config/gws/client_secret.json

# Remove any existing auth tokens (they're for the old client)
rm -f ~/.config/gws/credentials.json
rm -f ~/.config/gws/credentials.enc
rm -f ~/.config/gws/credentials.*.enc

echo "Credentials installed to ~/.config/gws/client_secret.json"
```

### Step 7: Authenticate with gws

```bash
gws auth login
```

This opens a browser window for OAuth consent. The user should:
1. Select their Google account
2. Click "Continue" on the "unverified app" warning (expected for test apps)
3. Grant the requested permissions
4. See "Authentication successful" in the terminal

**Verify**:
```bash
gws auth status
```
Should show the authenticated account.

### Step 8: Test the connection

Run a quick test to verify everything works:

```bash
# Test Gmail access
gws gmail users getProfile --format json

# Test Calendar access
gws calendar calendarList list --format json --params '{"maxResults": 1}'

# Test Drive access
gws drive files list --format json --params '{"pageSize": 1}'
```

All three should return valid JSON responses.

### Step 9: Summary

Print a summary:

```
GWS Personal App Setup Complete

  Project:       PROJECT_NAME (PROJECT_ID)
  Client:        ~/.config/gws/client_secret.json
  Credentials:   ~/.config/gws/credentials.json
  Account:       USER_EMAIL

  APIs Enabled:
    Gmail API          ✓
    Calendar API       ✓
    Drive API          ✓
    Docs API           ✓
    Sheets API         ✓
    Keep API           ✓

  OAuth:             Desktop app (Testing mode)
  Test Users:        USER_EMAIL

  Try it:  gws gmail users getProfile
```

## Troubleshooting

### "Access blocked: This app's request is invalid"
- The OAuth consent screen is not configured. Re-do Step 4.

### "Error 403: access_denied"
- The user's email is not added as a test user. Go to OAuth consent screen → Test Users → Add.

### "This app is blocked"
- Google occasionally blocks new OAuth apps. Wait a few minutes and retry.

### "Quota exceeded"
- You may need to request quota increases in the APIs & Services → Quotas page.

### Want to go back to the bundled credentials?
```bash
# Remove personal credentials
rm ~/.config/gws/client_secret.json
rm ~/.config/gws/credentials.json

# The app will re-copy the bundled client_secret.json on next launch
```
