# Observer Session — Product Spec

## Problem

Users currently have to manually create skill files (.skill.md) to teach Fazm their personal preferences and rules — shopping habits, delivery preferences, website registration patterns, etc. This works for power users but is a non-starter for regular users. The AI should learn these automatically from observing the user's behavior and conversations.

## Solution

A parallel ACP session ("the Observer") that runs alongside every main conversation. It watches the conversation transcript and screen context, extracts preferences and patterns, organizes knowledge, and occasionally interacts with the user to confirm or clarify what it learned.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                Main ACP Session                      │
│  (interactive — user ↔ agent conversation)           │
│                                                      │
│  Reads preferences from DB at each turn              │
│  Never aware of the observer directly                │
└──────────┬──────────────────────┬────────────────────┘
           │ conversation turns   │ (shared DB)
           │ (piped as context)   │
           ▼                      │
┌──────────────────────────────── │ ────────────────────┐
│           Observer ACP Session   │                    │
│  (parallel — same Opus model)    │                    │
│                                  │                    │
│  Inputs:                         │                    │
│  • Batched conversation turns    │                    │
│  • Periodic screenshots          │                    │
│  • Current knowledge graph       │                    │
│  • Current preferences           │                    │
│                                  │                    │
│  Outputs:                        ▼                    │
│  • Writes to user_preferences table ──────────────────│──→ Main session reads these
│  • Writes to local_kg_nodes/edges                     │
│  • Queues UI cards (observer_cards table)              │
│  • Updates ai_user_profiles                           │
└───────────────────────────────────────────────────────┘
```

## Observer Responsibilities

### 1. Silent Learning (no UI, always on)
- Extract preferences and rules from conversation ("I always use Amazon", "ship to my office")
- Update knowledge graph with new entities and relationships
- Detect repeated multi-step workflows (candidate for auto-skill generation)
- Maintain a living user profile summary

### 2. User Interaction (via UI cards)
When the observer needs user input, it writes a card to `observer_cards` table. The Swift UI renders these as interactive elements.

**Card types:**

#### Confirmation Card
Observer detected a preference and wants to confirm.
```
┌─ Observer ─────────────────────────────────────────┐
│ Looks like you prefer Amazon for electronics.      │
│ Save as a default?                                 │
│                                                    │
│  [Yes]    [No]    [More options]                   │
└────────────────────────────────────────────────────┘
```

#### Choice Card
Observer detected ambiguity and needs clarification.
```
┌─ Observer ─────────────────────────────────────────┐
│ You've used two shipping addresses recently.       │
│ Which is your default?                             │
│                                                    │
│  [123 Main St, SF]    [456 Oak Ave, LA]            │
└────────────────────────────────────────────────────┘
```

#### Pattern Card
Observer detected a repeated workflow.
```
┌─ Observer ─────────────────────────────────────────┐
│ You've done "export PDF → email to client" 4       │
│ times this week. Want me to make it one command?   │
│                                                    │
│  [Create skill]    [Not now]    [Never ask]        │
└────────────────────────────────────────────────────┘
```

#### Insight Card (no action needed)
Observer shares something it learned.
```
┌─ Observer ─────────────────────────────────────────┐
│ Saved: your default delivery is same-day to your   │
│ office address when ordering before 2pm.           │
│                                                    │
│                                          [Undo]    │
└────────────────────────────────────────────────────┘
```

### 3. Session Start Summary
When the user opens a new session, the observer can surface 1-2 high-value items from what it learned in previous sessions:
```
┌─ Observer ─────────────────────────────────────────┐
│ Since last time:                                   │
│ • Learned 3 new preferences from your sessions     │
│ • Created a "client-report-export" skill from      │
│   your repeated workflow                           │
│                                                    │
│  [Review changes]    [Dismiss]                     │
└────────────────────────────────────────────────────┘
```

## UI Design Principles

1. **Observer cards are button-only** — the user never types to the observer. Text input always goes to the main agent. This eliminates "who am I talking to?" confusion.

2. **Cards appear inline in the chat** but are visually distinct — different background, "Observer" label, no avatar. They feel like margin notes, not messages.

3. **Cards are non-blocking** — the main conversation continues regardless. Cards queue up and appear at natural pauses (between turns, after task completion).

4. **Cards are dismissible** — swipe or tap X. Dismissed cards don't come back.

5. **Rate-limited** — max 2-3 cards per conversation. The observer batches its insights and picks the most valuable ones to surface. No notification fatigue.

6. **The observer never speaks as the agent** — it's always clearly labeled. The user should understand these are background observations, not the agent they're talking to responding.

## Data Model

### New Tables

#### `user_preferences`
```sql
CREATE TABLE user_preferences (
    id TEXT PRIMARY KEY,
    domain TEXT NOT NULL,        -- "shopping", "communication", "coding", "delivery", etc.
    key TEXT NOT NULL,           -- "preferred_store", "shipping_address", "code_style"
    value TEXT NOT NULL,         -- "Amazon", "123 Main St", "python_snake_case"
    confidence REAL DEFAULT 0.5, -- 0.0 to 1.0, increases with repeated observations
    source TEXT,                 -- "conversation", "screen", "onboarding", "user_confirmed"
    confirmed INTEGER DEFAULT 0, -- 1 if user explicitly confirmed via card
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

#### `observer_cards`
```sql
CREATE TABLE observer_cards (
    id TEXT PRIMARY KEY,
    card_type TEXT NOT NULL,     -- "confirmation", "choice", "pattern", "insight"
    title TEXT NOT NULL,
    body TEXT,
    options TEXT,                -- JSON array of button labels
    status TEXT DEFAULT 'pending', -- "pending", "shown", "acted", "dismissed"
    user_response TEXT,          -- which button was tapped
    priority REAL DEFAULT 0.5,  -- for ordering when multiple cards queue
    created_at TEXT NOT NULL,
    shown_at TEXT,
    acted_at TEXT
);
```

#### `observed_patterns`
```sql
CREATE TABLE observed_patterns (
    id TEXT PRIMARY KEY,
    pattern_type TEXT NOT NULL,  -- "workflow", "preference", "schedule"
    description TEXT NOT NULL,
    occurrence_count INTEGER DEFAULT 1,
    last_seen_at TEXT NOT NULL,
    skill_generated INTEGER DEFAULT 0, -- 1 if auto-skill was created
    created_at TEXT NOT NULL
);
```

### Modified Tables

#### `local_kg_nodes` — no schema change, observer writes to it
#### `local_kg_edges` — no schema change, observer writes to it
#### `ai_user_profiles` — no schema change, observer updates it

## Observer Session Configuration

### Session Key
`"observer"` — alongside existing `"main"` and `"onboarding"`

### Model
Opus (same as main session — this is a full intelligence, not a cheap extractor)

### Tools Available
- `execute_sql` — read/write preferences, patterns, cards, knowledge graph
- `capture_screenshot` — periodic screen context (max 1/minute)
- `save_knowledge_graph` — update user graph
- `query_browser_profile` — access browser-extracted profile data

### Tools NOT Available
- No `ask_followup` — observer doesn't talk to user directly via chat
- No onboarding tools
- No Playwright/macos-use — observer doesn't take actions

### System Prompt (summary)
```
You are the Observer — a parallel intelligence watching the user's conversation
with their AI agent and their screen activity. Your job:

1. LEARN: Extract preferences, rules, habits, and patterns from what you see.
   Write them to user_preferences with appropriate confidence scores.

2. ORGANIZE: Keep the knowledge graph updated with new entities and relationships.
   Update the user profile when significant new information emerges.

3. NOTICE: Detect repeated workflows that could become automated skills.
   Track patterns in observed_patterns table.

4. ASK (sparingly): When you need user input, create a card in observer_cards.
   - Max 2-3 cards per conversation
   - Prefer insight cards (no action needed) over questions
   - Only ask when the answer materially changes how you'd serve the user
   - Never ask about trivial preferences — just save them at low confidence

5. SURFACE conclusions, not observations. Never say "I noticed you did X."
   Say "Saved: you prefer X" or "Should I make X your default?"

You receive:
- Batched conversation turns (every 5-10 messages)
- Periodic screenshots (1/minute during active sessions)
- Current state of preferences and knowledge graph

You are Opus. Think deeply. Connect dots across sessions. Build a rich,
accurate model of this person over time.
```

## Conversation Feed Mechanism

The ACP bridge pipes main session turns to the observer in batches:

1. Main session processes a user turn + agent response
2. Bridge appends the turn pair to an observer input buffer
3. Every 5 turns (or when the user goes idle for 30s), the bridge sends the batch to the observer session as a `session/prompt` with:
   - The conversation batch
   - A fresh screenshot (if user was active)
   - Current preference count and last-updated timestamp

The observer processes asynchronously. Its outputs (DB writes, cards) happen independently of the main session's flow.

## Preference Injection into Main Session

`ChatProvider.swift` gets a new `formatPreferencesSection()` method:

```swift
func formatPreferencesSection() -> String {
    // Load from user_preferences table
    // Group by domain
    // Only include confirmed OR high-confidence (>0.7) preferences
    // Format as:
    // <user_preferences>
    // Shopping: prefers Amazon, same-day delivery to office address
    // Communication: formal tone for work emails, casual for personal
    // Coding: Python, snake_case, prefers list comprehensions
    // </user_preferences>
}
```

This is called at every `session/prompt` in the main session, so the agent naturally uses the preferences without being told to.

## Implementation Phases

### Phase 1: Silent Learning + Preference Injection
- New DB tables (user_preferences, observed_patterns)
- Observer ACP session that receives conversation batches
- Observer extracts preferences and writes to DB
- Main session reads preferences into system prompt
- **No UI changes** — the observer is invisible but the main agent gets smarter

### Phase 2: Observer Cards
- New DB table (observer_cards)
- Swift UI component for rendering cards inline in chat
- Observer writes cards, UI renders them
- Button taps write back to observer_cards, observer reads responses
- Rate limiting (max 2-3 per conversation)

### Phase 3: Pattern Detection + Auto-Skills
- Observer tracks repeated workflows in observed_patterns
- When count >= 3, generates a .skill.md and offers via pattern card
- Session start summary cards

### Phase 4: Screen Context Intelligence
- Periodic screenshot analysis (not just on-demand)
- Observer understands what app the user is in, what they're looking at
- Cross-references screen context with conversation to build richer model
- "You were looking at X while asking about Y" inference

## Open Questions

1. **Cost**: Running Opus in parallel doubles the API cost per conversation. Is this acceptable for all users, or should it be a premium feature / opt-in?

2. **Privacy**: The observer sees everything. Should there be an easy way to pause it? A "private mode" toggle?

3. **Preference conflicts**: What happens when the observer learns something that contradicts a previous preference? Always ask, or auto-update with lower confidence?

4. **Cross-device**: Preferences are stored locally in SQLite. If the user has multiple devices, how do preferences sync? (Backend table? Or local-only for now?)

5. **Preference decay**: Should old, unconfirmed preferences lose confidence over time? A preference learned 6 months ago and never confirmed might be stale.
