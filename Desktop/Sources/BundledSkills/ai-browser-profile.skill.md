---
name: ai-browser-profile
description: "Query the user's browser-extracted profile: identity, accounts, tools, contacts, addresses, payments. Use when the user asks about their own info or you need personal context."
---

# AI Browser Profile

Locally-extracted profile of the user built from their browser data (autofill, saved logins, history, bookmarks, WhatsApp, LinkedIn). Stored in `~/ai-browser-profile/memories.db`. Nothing leaves the machine.

## When to use `query_browser_profile`

Use this tool proactively whenever the user asks about themselves or you need personal context:

| User asks... | Query |
|---|---|
| "What's my email?" | query: "email address", tags: ["contact_info"] |
| "What accounts do I have?" | query: "saved accounts", tags: ["account"] |
| "What tools do I use?" | query: "tools and services", tags: ["tool"] |
| "Find contact X" | query: "X", tags: ["contact"] |
| "What's my address?" | query: "home address", tags: ["address"] |
| "What card do I use?" | query: "payment card", tags: ["payment"] |
| "Who am I?" / profile | query: "profile", tags: ["identity"] |

## Tool parameters

```
query_browser_profile(
  query: string,           // natural language query
  tags?: string[]          // optional: identity, contact_info, account, tool,
                           //           address, payment, contact, work, knowledge
)
```

Returns ranked results from the local database. Results are self-ranking — frequently accessed ones surface automatically.

## Full profile

To get the complete user profile in one call:
```
query_browser_profile(query: "full profile")
```

Returns name, emails, phone, addresses, payment info, companies, top tools, accounts.

## Availability

Requires browser data extraction during onboarding. If no data found, tell the user to re-run: `npx ai-browser-profile init && python ~/ai-browser-profile/extract.py`
