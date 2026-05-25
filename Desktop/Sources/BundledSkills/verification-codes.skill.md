---
name: verification-codes
description: Use when the user asks Fazm to log into a service, finish a signup, recover an account, or otherwise complete a flow that just texted, iMessaged, or messaged them a verification code, OTP, 2FA code, or 6-digit code. Retrieves the most recent code from Messages.app, WhatsApp, or system notifications so the user does not have to read it out.
---

# Verification Codes (SMS / 2FA / OTP)

Pull the latest one-time code a service sent the user, without making them stop what they are doing and dictate it.

Use this whenever a login, signup, password reset, or sensitive action triggers a code being sent to the user's phone, iMessage, WhatsApp, or notification center. Do NOT ask the user "what is the code?" first; look it up.

## Order of operations

Codes can arrive on any channel. Check in this order, stopping at the first hit that is unambiguously fresh (sent in the last 5 minutes):

1. **Messages.app (SMS + iMessage)** via SQLite. Fastest, no UI.
2. **WhatsApp** via the `whatsapp` MCP. Many international services (banks, crypto, Telegram itself) send codes here.
3. **macOS Notification Center / Mail** via `macos-use` as a last resort.

Always confirm the code matches the service the user is trying to use (sender name, body mentions the brand). If two services sent codes in the same window, ask which one is for the flow at hand rather than guessing.

## Method 1: Messages.app via SQLite

Run via Bash. This reads `~/Library/Messages/chat.db` directly. It works for both SMS and iMessage.

```bash
sqlite3 ~/Library/Messages/chat.db "SELECT text, datetime(date/1000000000 + 978307200, 'unixepoch', 'localtime') AS received FROM message WHERE (text LIKE '%code%' OR text LIKE '%verif%' OR text LIKE '%OTP%' OR text LIKE '%passcode%' OR text GLOB '*[0-9][0-9][0-9][0-9][0-9][0-9]*') AND date/1000000000 + 978307200 > strftime('%s','now') - 600 ORDER BY date DESC LIMIT 5;"
```

The `date > now - 600` clause limits results to the last 10 minutes so stale codes do not get picked up by mistake. Extract the digits from the matching row.

If `sqlite3` errors with "unable to open database file", Full Disk Access is missing for the host (Fazm or Terminal). Tell the user once: "Grant Full Disk Access to Fazm in System Settings, Privacy and Security, Full Disk Access, then try again." Then fall through to the next method instead of looping on the same error.

## Method 2: WhatsApp via MCP

WhatsApp is the right channel for codes from services that prefer it (Telegram login codes, some banks, some crypto exchanges, and most non-US services).

```
whatsapp_status                          # confirm the app is running and accessibility is granted
whatsapp_list_chats                      # find the top of the chat list; the verification sender is usually pinned at the top because it just messaged
whatsapp_open_chat(index: 0)             # open the most recent chat if it looks like the sender (e.g. "Telegram", "WhatsApp", a short code)
whatsapp_get_active_chat                 # verify
whatsapp_read_messages                   # read the most recent message and extract the code
```

If the right sender is not at the top, fall back to `whatsapp_search` with the service name (e.g. "Telegram", "Binance"). Never send a message from this skill; this is read-only.

If the WhatsApp tools return an accessibility permission error, do NOT try WhatsApp Web in a browser as a fallback (contenteditable focus issues make it unreliable). Tell the user to grant Accessibility in System Settings, Privacy and Security, Accessibility, then move on to Method 3.

## Method 3: Notification Center, Mail, or the sender's own app

Last-resort fallbacks via `macos-use`:

- **Notification Center**: open it (`macos-use_press_key_and_traverse` with `key="F12"` or click the clock in the menu bar) and read recent banners. Many code-sending services show the code directly in the notification body without the user having to open the app.
- **Mail.app**: if the user said "I got an email with a code", drive Mail.app via `macos-use` (or use the `gmail` skill if their account is Google) and read the most recent matching message.
- **The sender's native app**: for codes that only appear inside an app (e.g. Authy, Google Authenticator, banking apps), open it and read the on-screen value.

For Google Authenticator-style TOTP apps, prefer reading the visible code via the app rather than guessing the seed; never try to extract a TOTP secret from the user's machine on your own.

## Safety rules

- **Only read the most recent code.** Do not surface older codes; they may have already been used, and showing them adds noise.
- **Match the code to the sender.** Confirm the message body or sender name references the brand the user is interacting with. If unclear, ask.
- **Never type the code anywhere the user did not ask you to.** If the user said "log me into chase.com", typing the code into the Chase login is what was asked. Typing it into a Notes doc, a Slack message, or any other surface is a critical failure.
- **Never speak the code aloud via TTS unless the user explicitly asked for it.** Voice readout of a 2FA code is a security hole if someone else is in earshot.
- **Do not log codes to chat history in plain form when avoidable.** It is fine to use the code internally for the requested action; if you must reference it in your reply, mask the middle digits (e.g. `12••56`).
- **One attempt per code.** If a code fails (expired, mistyped, wrong service), tell the user and ask them to re-trigger the send rather than scraping the same channel for older codes.

## What this skill is NOT for

- Setting up new 2FA factors (use the service's own enrollment flow).
- Storing TOTP seeds or backup codes (those belong in the user's password manager, not in Fazm).
- Sending verification codes on the user's behalf (out of scope, and likely a phishing footgun).
