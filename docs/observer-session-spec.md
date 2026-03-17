# Observer Session — Product Spec

## Problem

Users currently have to manually create skill files (.skill.md) to teach Fazm their personal preferences and rules — shopping habits, delivery preferences, website registration patterns, etc. This works for power users but is a non-starter for regular users. The AI should learn these automatically from observing the user's behavior and conversations.

## Solution

A parallel ACP session ("the Observer") that runs alongside every main conversation. Same Opus model. It watches the conversation transcript and screen context, learns about the user, updates the knowledge graph, stores observations via Hindsight, and can create new skills — all using existing infrastructure.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                Main ACP Session                      │
│  (interactive — user ↔ agent conversation)           │
│                                                      │
│  Reads knowledge graph + Hindsight at each turn      │
│  Never aware of the observer directly                │
└──────────┬──────────────────────┬────────────────────┘
           │ conversation turns   │ (shared state)
           │ (piped as context)   │
           ▼                      │
┌─────────────────────────────────│────────────────────┐
│           Observer ACP Session  │                    │
│  (parallel Opus — same model)   │                    │
│                                 │                    │
│  Inputs:                        │                    │
│  • Batched conversation turns   │                    │
│  • Periodic screenshots         │                    │
│                                 │                    │
│  Outputs:                       ▼                    │
│  • Knowledge graph (save_knowledge_graph) ───────────│──→ Main session reads via SQL
│  • Hindsight (retain/recall/reflect) ────────────────│──→ Main session recalls
│  • Skills (~/.claude/skills/*.skill.md) ─────────────│──→ Main session discovers
│  • Observer cards (observer_activity table) ──────────│──→ UI renders inline
└──────────────────────────────────────────────────────┘
```

## What the Observer Uses (all existing)

| Capability | Infrastructure | Already exists? |
|------------|---------------|-----------------|
| Store facts about the user | `local_kg_nodes` + `local_kg_edges` | Yes |
| Semantic memory | Hindsight MCP (`retain`, `recall`, `reflect`) | Yes |
| Create automations | Write `.skill.md` files to `~/.claude/skills/` | Yes |
| Query user profile | `query_browser_profile`, `ai_user_profiles` | Yes |
| Read/write DB | `execute_sql` | Yes |
| See the screen | `capture_screenshot` | Yes |
| Interact with user | **observer_activity table** (new) | **No — one new table** |

## The One New Table: `observer_activity`

Everything the observer does — insights, questions, skill creation notices, learned facts — goes here. One table, flexible schema.

```sql
CREATE TABLE observer_activity (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,          -- "card", "insight", "skill_created", "kg_update", "pattern"
    content TEXT NOT NULL,       -- JSON blob: {title, body, options, ...}
    status TEXT DEFAULT 'pending', -- "pending", "shown", "acted", "dismissed"
    user_response TEXT,          -- which button was tapped (for cards)
    created_at TEXT NOT NULL,
    acted_at TEXT
);
```

This is the observer's activity log AND the UI card queue. The Swift UI polls for `status = 'pending'` rows with `type = 'card'` and renders them.

### Example rows

**A learned preference (silent, no UI):**
```json
{
  "id": "obs_001",
  "type": "insight",
  "content": "{\"fact\": \"prefers Amazon for electronics\", \"kg_node_id\": \"n_42\"}",
  "status": "logged",
  "created_at": "2026-03-17T10:30:00Z"
}
```

**A question for the user (shows as card):**
```json
{
  "id": "obs_002",
  "type": "card",
  "content": "{\"title\": \"Two shipping addresses used recently\", \"body\": \"Which should be your default?\", \"options\": [\"123 Main St, SF\", \"456 Oak Ave, LA\"]}",
  "status": "pending",
  "created_at": "2026-03-17T10:31:00Z"
}
```

**A skill was auto-created:**
```json
{
  "id": "obs_003",
  "type": "skill_created",
  "content": "{\"skill_name\": \"client-report-export\", \"description\": \"Export PDF and email to client in one step\", \"path\": \"~/.claude/skills/client-report-export/SKILL.md\"}",
  "status": "pending",
  "created_at": "2026-03-17T10:35:00Z"
}
```

## Observer Responsibilities

### 1. Learn — Update the Knowledge Graph
The observer uses `save_knowledge_graph` (existing tool) to add nodes and edges as it learns about the user from conversations and screen context. Preferences, people, tools, habits — all go into the same graph the onboarding built.

### 2. Remember — Use Hindsight
The observer calls `retain` (Hindsight MCP) to store observations that don't fit neatly into a graph — nuanced context, conversation summaries, behavioral patterns. The main session can `recall` these naturally.

### 3. Automate — Create Skills & Integrations (always confirm first)
When the observer detects a repeated workflow (3+ occurrences), a workaround worth preserving, or a system integration the user needs, it **drafts** the skill but does NOT write it to disk. Instead, it surfaces a card describing what the skill would do and asks the user to approve.

**Hard rule: The observer never creates a skill without user confirmation.** Skills change what the agent can *do* — the user must consent.

### 4. Ask — Surface Cards (sparingly)
When the observer needs user input, it writes a `type = 'card'` row to `observer_activity`. The UI renders it inline in the chat.

## What's Silent vs. What Requires Confirmation

| Action | Silent or Card? | Why |
|--------|----------------|-----|
| Write to knowledge graph | **Silent** | Background context, doesn't change behavior |
| Retain to Hindsight | **Silent** | Background context, doesn't change behavior |
| Update user profile | **Silent** | Background context, doesn't change behavior |
| Create a new skill | **Card — always** | Changes what the agent can do |
| Resolve ambiguity (e.g., which address?) | **Card** | Needs user input to be accurate |
| Significant behavioral insight | **Card (optional)** | User might want to know / correct it |

The principle: **enriching context is silent, adding capabilities requires consent.**

## UI: Observer Cards

Cards appear inline in the chat but are visually distinct — different background, "Observer" label, button-only interaction.

### Skill Creation Card (most important card type)
```
┌─ Observer ─────────────────────────────────────────┐
│ I've seen you do "export PDF → email to client"    │
│ 4 times. I can make this a single command.         │
│                                                    │
│ What the skill would do:                           │
│ 1. Export current doc as PDF                       │
│ 2. Attach to email to last-used client address     │
│ 3. Send with your standard sign-off                │
│                                                    │
│  [Create skill]    [Edit first]    [Skip]          │
└────────────────────────────────────────────────────┘
```

"Edit first" passes the draft skill to the main chat so the user can refine it with the agent before saving.

### Workaround Preservation Card
```
┌─ Observer ─────────────────────────────────────────┐
│ The agent found a workaround when the X API was    │
│ down — used Playwright to do it via the web UI.    │
│ Save this as a fallback skill?                     │
│                                                    │
│  [Save as skill]    [Skip]                         │
└────────────────────────────────────────────────────┘
```

### Clarification Card
```
┌─ Observer ─────────────────────────────────────────┐
│ You've used two shipping addresses recently.       │
│ Which is your default?                             │
│                                                    │
│  [123 Main St, SF]    [456 Oak Ave, LA]            │
└────────────────────────────────────────────────────┘
```

### UI Rules
1. **Button-only** — user never types to the observer. Text input always goes to the main agent.
2. **Non-blocking** — main conversation continues. Cards appear at natural pauses.
3. **Dismissible** — tap X or swipe. Dismissed = `status: 'dismissed'`.
4. **Rate-limited** — max 2-3 cards per conversation. Observer picks the most valuable.
5. **Clearly labeled** — always shows "Observer" label. Never confused with the main agent.

### Card Interaction Flow
1. Observer writes row to `observer_activity` with `type: 'card'`, `status: 'pending'`
2. Swift UI polls table, renders card inline in chat
3. User taps a button → Swift writes `user_response` and sets `status: 'acted'`
4. Observer reads the response on next batch and acts accordingly (e.g., creates skill, updates KG)

## Observer Session Configuration

### Session Key
`"observer"` — alongside existing `"main"` and `"onboarding"`

### Model
Opus (same as main session)

### Tools Available
- `execute_sql` — read/write observer_activity, knowledge graph, profiles
- `capture_screenshot` — periodic screen context (max 1/minute)
- `save_knowledge_graph` — update user graph with new nodes/edges
- `query_browser_profile` — access browser-extracted profile data
- `load_skill` — read existing skills to avoid duplicates
- Hindsight MCP — `retain`, `recall`, `reflect`
- File write access to `~/.claude/skills/` — for creating new skills

### Tools NOT Available
- No `ask_followup` — observer doesn't talk to user directly via chat
- No onboarding tools
- No Playwright/macos-use — observer observes, it doesn't act

### System Prompt

```
You are the Observer — a parallel intelligence running alongside the user's
conversation with their AI agent. You watch the conversation and screen
activity. Your job is to build an ever-richer understanding of this person
and make their agent more effective over time.

## Your tools

1. KNOWLEDGE GRAPH (save_knowledge_graph)
   Add nodes and edges as you learn about the user. Preferences, people,
   projects, tools, habits, rules — all belong in the graph. This is the
   same graph built during onboarding. Extend it continuously.

2. HINDSIGHT (retain, recall, reflect)
   Store nuanced observations, conversation summaries, and behavioral
   context. Use retain for new observations. Use reflect periodically
   to synthesize patterns across multiple observations.

3. SKILLS & INTEGRATIONS (write to ~/.claude/skills/) — REQUIRES USER CONFIRMATION
   When you detect a repeated workflow (3+ times), a workaround worth
   preserving, or a system integration the user needs, draft the full
   skill: SKILL.md + any helper scripts (.sh, .applescript, .py).

   Do NOT write files to disk yet. Store the complete draft in the
   observer_activity card JSON under "draft_skill" with all file
   contents. Surface a card with [Create skill], [Edit first], [Skip].

   On [Create skill]: write all files to ~/.claude/skills/{name}/,
   chmod +x any scripts. The main session auto-discovers it.
   On [Edit first]: pass draft to main session for user refinement.

   Three levels of skills you can create:
   - Instruction-only: SKILL.md that teaches the agent to use existing
     tools (bash, Playwright, SQL). For preferences, rules, knowledge.
   - Skill + scripts: SKILL.md + helper shell/AppleScript/Python scripts
     in the same folder. For integrations (Reminders, APIs, workflows).
   - Never create MCP servers — that's a developer task.

4. OBSERVER CARDS (execute_sql → observer_activity table)
   When you need user input, write a card. Use sparingly — max 2-3 per
   conversation. Card format:
   INSERT INTO observer_activity (id, type, content, status, created_at)
   VALUES ('obs_xxx', 'card', '{"title":"...","body":"...","options":["A","B"]}',
           'pending', datetime('now'));

## What is silent vs. what requires a card
- SILENT: Knowledge graph updates, Hindsight retains, profile updates.
  These enrich context — the user doesn't need to approve them.
- CARD REQUIRED: Skill creation, resolving ambiguity, significant
  behavioral rules. These change capabilities or need accuracy.
- RULE: Enriching context = silent. Adding capabilities = confirm first.

## What you receive
- Batched conversation turns (every 5-10 messages from the main session)
- Periodic screenshots (1/minute when user is active)
- The user's response to any cards you surfaced (poll observer_activity)

## Principles
- Surface CONCLUSIONS, not observations. "Saved: you prefer X" not "I noticed you did X"
- Write to the knowledge graph liberally — it's cheap and the main agent reads it
- Use Hindsight for context that's too nuanced for structured data
- Create skills only for clear, repeated patterns — not one-off workflows
- Ask the user only when the answer materially changes how you'd serve them
- You are Opus. Think deeply. Connect dots across sessions.
```

## Skill Structure & Integrations

### Where skills live

Skills are auto-discovered from `~/.claude/skills/{name}/SKILL.md` by `ChatProvider.swift` (lines 1750-1762). It scans on every `discoverClaudeConfig()` call — no restart needed, no registration step. If the observer creates `~/.claude/skills/apple-reminders/SKILL.md` after user confirmation, the main session discovers it on the very next prompt.

### Three levels of skills

| Level | Contents | When to use | Observer can create? |
|-------|----------|-------------|---------------------|
| **Instruction-only** | `SKILL.md` only | When existing tools (bash, Playwright, SQL) are enough | Yes |
| **Skill + scripts** | `SKILL.md` + helper `.sh`/`.applescript`/`.py` files | When the workflow needs reliable, reusable commands | Yes |
| **Skill + MCP server** | `SKILL.md` + full MCP server package | When structured tool definitions and complex state are needed | No — developer task |

### Skill folder structure

The `~/.claude/skills/{name}/` directory is a folder, not a single file. `load_skill` reads `SKILL.md`, but the skill can reference sibling scripts that the main agent calls via bash.

```
~/.claude/skills/apple-reminders/
├── SKILL.md                ← loaded by load_skill, references scripts below
├── add-reminder.sh         ← called via bash by the main agent
├── list-reminders.sh
└── reminders.applescript   ← helper AppleScript used by the shell scripts
```

The SKILL.md would contain:
```markdown
---
name: apple-reminders
description: "Manage Apple Reminders — add, list, complete, and organize reminders"
---

# Apple Reminders Integration

## Available scripts (in this skill's directory)
- `add-reminder.sh <list> <title> [--due <date>] [--notes <text>]`
- `list-reminders.sh [list] [--incomplete-only]`

## When to use
When the user asks to create reminders, check their lists, or manage tasks
that should go to Apple Reminders.

## How to call
Run the scripts via bash. The skill directory is:
~/.claude/skills/apple-reminders/
```

### Integration examples the observer would create

**Apple Reminders** (skill + scripts):
- Observer sees user repeatedly asking "remind me to..." or "add to my groceries list"
- Drafts a skill with AppleScript-based shell scripts for CRUD operations
- Card: "You use Reminders a lot. I can create an integration so the agent manages them directly. [Create] [Edit first] [Skip]"

**Shopping preferences** (instruction-only skill):
- Observer sees user's shopping patterns across conversations
- Drafts a skill that documents: preferred stores, delivery rules, payment preferences, items to avoid
- The skill is pure instructions — no scripts needed because the agent uses Playwright/browser for shopping

**API fallback workaround** (skill + scripts):
- Observer watches the agent discover that an API is down and fall back to Playwright
- Drafts a skill that documents the workaround, plus a helper script that checks API health first
- Card: "The agent found a workaround for X. Save it as a fallback? [Save as skill] [Skip]"

**Client report workflow** (skill + scripts):
- Observer sees user do "export PDF → email to client" 4 times
- Drafts a skill with a shell script that chains the steps
- Card shows the workflow steps and offers [Create] [Edit first] [Skip]

### What the observer drafts vs. what it writes

When the observer prepares a skill, it stores the full draft (SKILL.md content + any script contents) in the `observer_activity` table as part of the card's JSON content. Nothing is written to disk until the user approves.

```json
{
  "type": "card",
  "content": {
    "title": "Create Apple Reminders integration?",
    "body": "I've seen you manage reminders in 5 conversations...",
    "options": ["Create skill", "Edit first", "Skip"],
    "draft_skill": {
      "name": "apple-reminders",
      "files": {
        "SKILL.md": "---\nname: apple-reminders\n...",
        "add-reminder.sh": "#!/bin/bash\nosascript ...",
        "list-reminders.sh": "#!/bin/bash\nosascript ..."
      }
    }
  }
}
```

On [Create skill]: the observer writes all files to `~/.claude/skills/apple-reminders/` and marks scripts executable.

On [Edit first]: the draft content is passed to the main chat session so the user can refine it with the agent.

## Conversation Feed Mechanism

The ACP bridge pipes main session turns to the observer in batches:

1. Main session processes a user turn + agent response
2. Bridge appends the turn pair to an observer input buffer
3. Every 5 turns (or when the user goes idle for 30s), the bridge sends the batch to the observer session as a `session/prompt` with:
   - The conversation batch
   - A fresh screenshot (if user was active)
4. The observer processes asynchronously — its outputs (KG updates, Hindsight retains, skill files, cards) happen independently of the main session

## How the Main Session Benefits

The main session already reads from all the stores the observer writes to:

| Observer writes to | Main session reads via | Already wired? |
|-------------------|----------------------|----------------|
| `local_kg_nodes/edges` | `execute_sql` + system prompt context | Yes |
| Hindsight | `recall` MCP tool | Yes |
| `~/.claude/skills/` | Skill discovery in `ChatProvider.swift` | Yes |
| `ai_user_profiles` | `formatAIProfileSection()` | Yes |

No new "preference injection" code needed. The observer enriches the same stores the main session already consults.

## Implementation Phases

### Phase 1: Observer Session + Knowledge Graph Learning
- One new DB table (`observer_activity`)
- Observer ACP session that receives conversation batches
- Observer updates knowledge graph via `save_knowledge_graph`
- Observer stores context via Hindsight `retain`
- **No UI changes** — the main agent just gets smarter because the KG and Hindsight are richer

### Phase 2: Observer Cards
- Swift UI component for rendering cards inline in chat
- Poll `observer_activity` for `type='card', status='pending'`
- Button taps write back to table
- Observer reads responses and acts
- Rate limiting (max 2-3 per conversation)

### Phase 3: Auto-Skill & Integration Creation
- Observer detects repeated workflows, workarounds, and integration opportunities
- Drafts full skill packages (SKILL.md + helper scripts) stored in card JSON
- Surfaces card with [Create skill] [Edit first] [Skip]
- On approval: writes files to `~/.claude/skills/{name}/`, chmod +x scripts
- Main session auto-discovers new skills on next prompt
- Covers all three levels: instruction-only, skill + scripts, and integrations

### Phase 4: Screen Context Intelligence
- Periodic screenshot analysis (not just on-demand)
- Observer understands what app the user is in, what they're working on
- Cross-references screen context with conversation for richer KG updates

## Open Questions

1. **Cost**: Running Opus in parallel doubles API cost. Premium feature, opt-in, or default for all?

2. **Privacy**: Should there be a "pause observer" toggle? Private mode?

3. **Hindsight vs KG boundary**: When should the observer use `save_knowledge_graph` vs Hindsight `retain`? Rule of thumb: structured facts (entities, relationships) → KG. Nuanced context (behavioral patterns, conversation summaries) → Hindsight.

4. **Skill quality**: Auto-generated skills need to be good enough to use immediately. Should the observer test them before surfacing, or always ask the user to review?

5. **Cross-session continuity**: The observer session resets each app launch. Its memory persists through KG + Hindsight + observer_activity table. Is that sufficient, or does it need its own persistent context?
