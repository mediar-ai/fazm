---
name: social-autoposter
description: "Automate social media posting across Reddit, X/Twitter, LinkedIn, and Moltbook. Find threads, post comments, track engagement stats, and handle reply engagement. Use when: 'post to social', 'social autoposter', 'find threads', 'audit social posts', 'update post stats', 'engage replies'. Run /social-autoposter to start."
user_invocable: true
---

# Social Autoposter

Automates finding, posting, and tracking social media comments. Works with any agent that has browser automation and shell access.

## Quick Start

| Command | What it does |
|---------|-------------|
| `/social-autoposter` | Full posting run (find threads + post + log) |
| `/social-autoposter stats` | Update engagement stats via API |
| `/social-autoposter engage` | Scan and reply to responses on our posts |
| `/social-autoposter audit` | Full browser audit of all posts |

## Config

All personal settings live in `config.json` (copy from `config.example.json`). The skill reads this at runtime.

Key fields:
- `accounts` — platform usernames/handles
- `subreddits` — target subreddits to monitor
- `content_angle` — your unique perspective for authentic comments
- `projects` — your products/repos to mention when relevant (with topic keywords)
- `database` — path to SQLite DB

## Helper Scripts

Standalone Python scripts any agent can call directly. No LLM needed for these.

| Script | What it does |
|--------|-------------|
| `scripts/find_threads.py` | Find candidate threads via Reddit JSON + Moltbook API |
| `scripts/scan_replies.py` | Scan for new replies to our posts via API |
| `scripts/update_stats.py` | Fetch engagement stats via API, update DB |

Examples:
```bash
python3 scripts/find_threads.py --topic "macOS automation" --limit 5
python3 scripts/scan_replies.py
python3 scripts/update_stats.py --quiet
```

---

## Critical: No Parallel Posting

**NEVER launch multiple agents or parallel tasks for posting.** All posting operations (comments, replies, thread creation) MUST be done sequentially in a single agent. Reasons:
- There is only one shared browser — parallel agents fight over it and cause timeouts
- Parallel agents cause duplicate posts (same comment posted twice on the same thread)
- Browser lock conflicts lead to unpredictable failures

This applies to ALL posting workflows: comments on existing threads, self-replies with links, new thread creation, and reply engagement. Even if you have 5 threads to post on, do them one at a time in the same agent.

**After each post, always verify** by reloading the page and confirming the comment appears exactly once before moving to the next post.

---

## Workflow: Post (`/social-autoposter`)

Find a thread, draft a comment, post it, log it.

### 1. Rate limit check

```sql
SELECT COUNT(*) FROM posts WHERE posted_at >= datetime('now', '-24 hours')
```
If 40+ posts in the last 24 hours, stop. Max 40/day.

### 2. Find candidate threads

**Option A — Use the helper script (preferred, no browser needed):**
```bash
python3 scripts/find_threads.py --include-moltbook
```
This returns a JSON list of candidate threads with dedup already applied.

**Option B — Browse manually with browser automation:**
Browse `/new` and `/hot` across target subreddits (from `config.json`). Also check Moltbook via API.

### 3. Pick the best thread

Requirements:
- You have a genuine angle from your `content_angle` in `config.json`
- The thread hasn't been posted in before (check `thread_url` in DB)
- Your last 5 comments don't repeat the same talking points:
  ```sql
  SELECT our_content FROM posts ORDER BY id DESC LIMIT 5
  ```
- If no thread fits naturally, **stop**. Better to skip than force a bad comment.

### 4. Read the thread

Before commenting, read the full thread:
- Check tone (casual/technical/professional)
- Read top comments for length and style cues
- Note thread age (skip stale threads)
- Identify the best comment to reply to (high-upvote comments get more visibility)

### 5. Draft the comment

Follow the **Content Rules** section below. Key points:
- 2-3 sentences max, match thread energy
- First person, specific details from your experience
- No product links in top-level comments (use Tiered Reply Strategy for that)
- If it sounds like a blog post, rewrite it

### 6. Post it

**Reddit** (browser automation):
- Navigate to `old.reddit.com` thread URL
- Find the reply box (textarea with class `usertext-edit`)
- Type the comment, click submit
- Wait 2-3 seconds, verify the comment appeared
- Capture the permalink of the new comment
- Close the tab

**X/Twitter** (browser automation):
- Navigate to the tweet
- Type reply in the reply box, click Reply
- Verify the reply posted
- Capture the URL

**LinkedIn** (browser automation):
- Navigate to the post
- Type comment, click Post
- No stable URL available, note as posted

**Moltbook** (API — no browser needed):
```bash
source ~/social-autoposter/.env
curl -s -X POST -H "Authorization: Bearer $MOLTBOOK_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"title": "...", "content": "...", "type": "text", "submolt_name": "general"}' \
  "https://www.moltbook.com/api/v1/posts"
```
Verify: fetch post by UUID, check `verification_status` is `"verified"`.
On Moltbook, write as an agent: "my human" not "I".
Rate limit: max 1 post per 30 minutes.

### 7. Log to database

```sql
INSERT INTO posts (platform, thread_url, thread_author, thread_author_handle,
  thread_title, thread_content, our_url, our_content, our_account,
  source_summary, status, posted_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', datetime('now'));
```

### 8. Sync (if configured)

If `sync_script` is set in `config.json`, run it to push data to a remote database.

---

## Workflow: Stats (`/social-autoposter stats`)

Update engagement metrics for all posts. No browser needed.

**Preferred: use the helper script:**
```bash
python3 scripts/update_stats.py
python3 scripts/update_stats.py --quiet   # summary only
python3 scripts/update_stats.py --json    # machine-readable output
```

This fetches:
- **Reddit**: comment scores and thread stats via public JSON API. Detects deleted/removed.
- **Moltbook**: upvotes and comment counts via REST API. Detects deleted posts.

Updates `upvotes`, `comments_count`, `thread_engagement`, `engagement_updated_at` in the DB.

For **X/Twitter** stats (requires browser): use `/social-autoposter audit` instead.

---

## Workflow: Engage (`/social-autoposter engage`)

Discover replies to our posts and respond to them.

### Phase A: Scan for replies (no browser needed)

```bash
python3 scripts/scan_replies.py
```

This scans Reddit JSON API + Moltbook API for new replies. Inserts into `replies` table as `pending` or `skipped`.

Skip reasons: `too_short` (<5 words), `filtered_author` (AutoModerator, [deleted], self), `too_old` (>7 days), `deleted`.

### Phase B: Respond to pending replies (needs browser/API)

Query pending replies:
```sql
SELECT r.id, r.platform, r.their_author, r.their_content, r.their_comment_url,
       r.depth, p.thread_title, p.our_content
FROM replies r
JOIN posts p ON r.post_id = p.id
WHERE r.status='pending'
ORDER BY r.discovered_at ASC LIMIT 10
```

For each pending reply:
1. Draft a response (2-4 sentences, casual, expand the topic, ask follow-ups)
2. Apply the **Tiered Reply Strategy** for project mentions
3. Post via browser (Reddit/X) or API (Moltbook)
4. Update the reply record:
   ```sql
   UPDATE replies SET status='replied', our_reply_content=?, our_reply_url=?,
     replied_at=datetime('now') WHERE id=?
   ```

Max 5 replies per run.

### Phase C: X/Twitter replies (browser required)

X has no public API for notifications. To discover X replies:
1. Navigate to `https://x.com/notifications/mentions`
2. Extract mentions replying to your account
3. Filter out already-tracked reply IDs, light acknowledgments, and your own replies
4. Respond to substantive replies (max 5)
5. Log everything to `replies` table

---

## Workflow: Audit (`/social-autoposter audit`)

Full browser-based audit of all posts. Use for X/Twitter stats or visual verification.

1. Query all posts with URLs:
   ```sql
   SELECT id, platform, our_url, status, upvotes, views, comments_count
   FROM posts WHERE our_url IS NOT NULL ORDER BY posted_at DESC
   ```

2. Visit each URL via browser automation. Check:
   - `active`: visible and accessible
   - `deleted`: 404 or "this tweet has been deleted"
   - `removed`: marked as removed by moderator
   - `inactive`: thread locked or archived

3. Capture engagement metrics (upvotes, views, comments) and update DB.

4. Report summary: total checked, by status, top performers.

---

## Content Rules

1. **Write like you're texting a coworker.** Lowercase fine. Sentence fragments fine. Never start with "Makes sense" or "The nuance here is." If it sounds like a blog post, rewrite it.

2. **First person, specific.** Use concrete numbers and real experiences, not generalizations. Say "I" not "you" or "one."

3. **Reply to top comments, not just OP.** High-upvote comments get more eyeballs.

4. **Only comment when you have a real angle from your work.** Use `content_angle` from `config.json`. If the thread doesn't connect to your experience, skip it.

5. **No product links in top-level comments.** Earn attention first. Links come later via the Tiered Reply Strategy.

6. **On Moltbook, write as an agent.** Use "my human" not "I". First-person agent perspective.

7. **Log everything.** Every thread and comment goes in the database.

### Bad vs Good

BAD: "Makes sense — Claude already tries to `| tail -n 50` on its own but by then the tokens are already in context."
GOOD: "gonna try this — I run 5 agents in parallel and my API bill is becoming a second rent payment"

BAD: "What everyone here is describing is basically specification-driven development."
GOOD: "I spend more time writing CLAUDE.md specs than I ever spent writing code. the irony is I'm basically doing waterfall now and shipping faster than ever."

---

## Tiered Reply Strategy

When replying to comments on our posts, escalate project mentions based on conversation context.

**Tier 1 — Default (no link):** Genuine engagement. Expand the topic, ask follow-ups. Most replies.

**Tier 2 — Natural mention:** Conversation touches something you're building. Mention the project casually. Include link only if it adds value. Triggers:
- "what are you working on" / "what tool do you use"
- They describe a problem matching a project's `topics` from `config.json`
- Conversation is 2+ replies deep (genuine interest)

**Tier 3 — Direct ask:** They explicitly ask for a link, to try it, if it's open source. Give it immediately.

---

## Database Schema

```sql
-- Core tables (see schema.sql for full DDL)
posts        -- everything we post (platform, urls, content, engagement, status)
threads      -- threads we've discovered
our_posts    -- backward-compat post tracking
replies      -- replies to our posts and our responses
```

Key fields in `posts`: `id, platform, thread_url, thread_title, our_url, our_content, our_account, posted_at, status, upvotes, comments_count, views, source_summary`

Key fields in `replies`: `id, post_id, platform, their_author, their_content, our_reply_content, status (pending|replied|skipped|error), depth`

---

## Platform Reference

**Reddit:** Use `old.reddit.com` for reliable automation. Comment box: textarea with class `usertext-edit`. No posting API — browser only.

**X/Twitter:** Reply to existing tweets. 1-2 sentences ideal. No public API for notifications — browser only.

**LinkedIn:** Professional tone, brief. Comments don't have stable URLs. Browser only.

**Moltbook:** Full REST API, no browser needed. Base: `https://www.moltbook.com/api/v1`. Auth: `Bearer $MOLTBOOK_API_KEY`. Agent-first platform — write as an agent.
