---
name: social-autoposter-setup
description: "Set up social-autoposter for a new user. Interactive wizard that installs via npm, creates the database, configures accounts, verifies browser logins, and optionally sets up scheduled automation. Use when: 'set up social autoposter', 'install social autoposter', 'configure social posting'."
---

# Social Autoposter Setup

Interactive setup wizard for social-autoposter. Walk the user through configuration step by step.

## When to use

- First-time setup of social-autoposter
- Reconfiguring accounts or adding new platforms
- Troubleshooting a broken setup

## Prerequisites

- Node.js 16+ (for `npx`)
- Python 3.9+ with `pip3` for running helper scripts
- A browser automation tool (Playwright MCP, Selenium, etc.) for platform login verification

---

## Setup Flow

Run these steps in order. Ask the user for input at each step. Don't skip ahead.

### Step 1: Install via npm

Check if already installed:

```bash
ls ~/social-autoposter/schema-postgres.sql 2>/dev/null && echo "FOUND" || echo "NOT_FOUND"
```

If NOT_FOUND, install:
```bash
npx social-autoposter init
```

This copies all scripts, skill files, and config templates to `~/social-autoposter/`. It also:
- Creates `config.json` from `config.example.json` (if missing)
- Creates `.env` from `.env.example` (if missing) — includes pre-filled Neon `DATABASE_URL`
- Installs `psycopg2-binary` (Python driver for Neon)
- Symlinks `~/.claude/skills/social-autoposter` → `~/social-autoposter/skill`

To update scripts later without touching config/data:
```bash
npx social-autoposter update
```

Set `SKILL_DIR=~/social-autoposter` for the rest of this wizard.

### Step 2: Verify the Neon database connection

Load the env and test the connection:

```bash
source "$SKILL_DIR/.env"
python3 -c "
import psycopg2, os
conn = psycopg2.connect(os.environ['DATABASE_URL'])
cur = conn.cursor()
cur.execute(\"SELECT COUNT(*) FROM posts\")
print('Connected. Posts in DB:', cur.fetchone()[0])
conn.close()
"
```

Expected: `Connected. Posts in DB: <number>` (any number is fine, including 0).

If psycopg2 is missing: `pip3 install psycopg2-binary`

If the connection fails, check that `DATABASE_URL` is set in `$SKILL_DIR/.env`.

### Step 3: Configure accounts

`config.json` already exists at `$SKILL_DIR/config.json`. Edit it with the user's accounts.

Ask the user for each platform they want to use:

**Reddit:**
- "What's your Reddit username?" → set `accounts.reddit.username`
- Login method is always `browser` (Reddit has no public posting API)

**X/Twitter:**
- "What's your X handle?" → set `accounts.twitter.handle`
- Login method is always `browser`

**LinkedIn:**
- "What's your LinkedIn name?" → set `accounts.linkedin.name`
- Login method is always `browser`

**Moltbook** (optional):
- "Do you want to set up Moltbook? (y/n)"
- If yes: "What's your Moltbook username?" and "What's your Moltbook API key?"
- Edit `$SKILL_DIR/.env` and set `MOLTBOOK_API_KEY=<key>` (the file already exists from init)
- Set `accounts.moltbook.username` and `accounts.moltbook.api_key_env` in `config.json`

### Step 4: Configure content

This step is the most important one. Take your time. The quality of every future post depends on it.

---

**4a. Subreddits**

Ask: "Which subreddits do you want to post in? (comma-separated, or press enter for defaults)"

Default suggestion: `ClaudeAI, ClaudeCode, programming, webdev, devops`

Write the list to `config.json` under `subreddits`.

---

**4b. Content angle — interview the user**

Don't just ask for a one-liner. Run a short interview to understand who they are, then write the angle for them.

Ask these questions one at a time. Wait for each answer before asking the next.

**Question 1:** "What are you currently working on or building? Be specific — what does it actually do?"

**Question 2:** "What's your technical background? What languages, tools, or domains do you know well?"

**Question 3:** "What's something you've learned recently from your work that most people in your field don't know yet — or that surprised you?"

**Question 4:** "What's a recurring frustration or problem you've run into that you think others in your community also face?"

**Question 5:** "Do you have any unusual setup or workflow? (e.g. running multiple AI agents, building on niche platforms, working solo on something usually done by teams)"

After collecting all answers, synthesize them into a `content_angle` that:
- Is 2-4 sentences
- Is written in first person
- Names specific tools, numbers, and experiences (not generic claims)
- Captures what makes their perspective genuinely different from a typical developer

Show the draft to the user:
> "Here's the content angle I'll use to write comments in your voice:
> [DRAFT]
> Does this sound like you? Want to change anything?"

Refine based on their feedback. Only save to `config.json` when they confirm it.

**Example of a weak angle** (don't write like this):
> "Software developer with experience in AI and web development."

**Example of a strong angle** (aim for this):
> "Building a macOS desktop AI agent that controls the browser and writes code via voice. Running 5 Claude agents in parallel on the same codebase — learned the hard way that they need zero file overlap or everything breaks. API costs hit $800/month before I got aggressive about caching."

---

**4c. Projects**

Ask: "Do you have any open source projects or products you'd want to mention naturally when the topic comes up? (y/n)"

If yes, for each project run through:
- "What's the name?"
- "One sentence: what does it do?"
- "Website URL? (or leave blank)"
- "GitHub URL? (or leave blank)"
- "What topics or keywords would make it relevant to mention? (e.g. 'desktop automation, macOS, accessibility APIs')"

After each project, ask: "Any more projects to add? (y/n)"

Store each under `config.json` → `projects` array with fields: `name`, `description`, `website`, `github`, `topics` (array of strings).

The `topics` keywords are what trigger natural mentions — when someone in a thread mentions one of these topics, the agent knows this project is relevant to bring up.

### Step 5: Verify browser logins

For each configured platform, verify the user is logged in:

**Reddit:**
- Navigate to `https://old.reddit.com` using browser automation
- Check if a username appears in the top-right (logged in) or a "login" link (not logged in)
- If not logged in: "Please log into Reddit in your browser, then say 'done'"
- Re-check after they confirm

**X/Twitter:**
- Navigate to `https://x.com/home`
- Check if the home timeline loads (logged in) or a login page appears
- Same flow if not logged in

**LinkedIn:**
- Navigate to `https://www.linkedin.com/feed/`
- Check if the feed loads or a login page appears

**Moltbook:**
- Source the env file and test the API key:
  ```bash
  source ~/social-autoposter/.env
  curl -s -H "Authorization: Bearer $MOLTBOOK_API_KEY" "https://www.moltbook.com/api/v1/posts?limit=1"
  ```
- Check for a successful response (not an auth error)

Report which platforms are ready and which need attention.

### Step 6: Test run (dry run)

Run the thread finder to verify everything works:
```bash
python3 "$SKILL_DIR/scripts/find_threads.py" --limit 3
```

Show the user the candidate threads found. Don't post anything — just verify the pipeline works.

Rate limit is 40 posts per 24 hours (enforced by the script).

### Step 7: Set up automation (optional)

Ask: "Do you want posts to run automatically on a schedule? (y/n)"

If yes, and on macOS:
- The launchd plists are already in `$SKILL_DIR/launchd/`
- Symlink into `~/Library/LaunchAgents/`:
  ```bash
  ln -sf "$SKILL_DIR/launchd/com.m13v.social-autoposter.plist" ~/Library/LaunchAgents/
  ln -sf "$SKILL_DIR/launchd/com.m13v.social-stats.plist" ~/Library/LaunchAgents/
  ln -sf "$SKILL_DIR/launchd/com.m13v.social-engage.plist" ~/Library/LaunchAgents/
  launchctl load ~/Library/LaunchAgents/com.m13v.social-autoposter.plist
  launchctl load ~/Library/LaunchAgents/com.m13v.social-stats.plist
  launchctl load ~/Library/LaunchAgents/com.m13v.social-engage.plist
  ```
- Schedule: posting runs hourly, stats every 6 hours, reply engagement every 2 hours

If yes, and on Linux:
- Generate crontab entries:
  ```
  0 * * * * cd ~/social-autoposter && bash skill/run.sh
  0 */6 * * * cd ~/social-autoposter && bash skill/stats.sh
  0 */2 * * * cd ~/social-autoposter && bash skill/engage.sh
  ```

If no: "You can run manually anytime with `/social-autoposter`"

### Step 8: Summary

Read `config.json` accounts and compute each platform's stats URL:
- Twitter/X handle (strip leading `@`): `https://s4l.ai/stats/HANDLE`
- Reddit username: `https://s4l.ai/stats/USERNAME`
- LinkedIn name (URL-encoded spaces as `%20`): `https://s4l.ai/stats/NAME`
- Moltbook username: `https://s4l.ai/stats/MOLTBOOK_USERNAME`

Print a summary with real values substituted:
```
Social Autoposter Setup Complete

  Installed:   ~/social-autoposter  (v1.0.9 via npm)
  Database:    Neon Postgres (DATABASE_URL in .env)
  Config:      ~/social-autoposter/config.json
  Env:         ~/social-autoposter/.env
  Skill:       ~/.claude/skills/social-autoposter

  Platforms:
    Reddit:    u/USERNAME ✓
    X/Twitter: @HANDLE ✓
    LinkedIn:  NAME ✓
    Moltbook:  USERNAME ✓

  Rate limit:  40 posts per 24 hours
  Automation:  launchd (hourly post, 6h stats, 2h engage)

  Your live stats pages:
    X/Twitter: https://s4l.ai/stats/HANDLE
    Reddit:    https://s4l.ai/stats/USERNAME
    LinkedIn:  https://s4l.ai/stats/NAME
    Moltbook:  https://s4l.ai/stats/MOLTBOOK_USERNAME

  Try it:      /social-autoposter
  Update:      npx social-autoposter update
```

Tell the user: "Your stats pages are ready — they'll show posts as soon as your first run completes and syncs to Neon (happens automatically after each post run). Bookmark the links above."
