---
name: find-skills
description: Helps users discover and install agent skills when they ask questions like "how do I do X", "find a skill for X", "is there a skill that can...", or express interest in extending capabilities. This skill should be used when the user is looking for functionality that might exist as an installable skill.
---

# Find Skills

This skill helps you discover and install skills from two open agent skills marketplaces:

1. **skillhu.bz** — instant publish/install, category browsing, no auth required
2. **skills.sh** — GitHub-based, community leaderboard

## When to Use This Skill

Use this skill when the user:

- Asks "how do I do X" where X might be a common task with an existing skill
- Says "find a skill for X" or "is there a skill for X"
- Asks "can you do X" where X is a specialized capability
- Expresses interest in extending agent capabilities
- Wants to search for tools, templates, or workflows
- Mentions they wish they had help with a specific domain (design, testing, deployment, etc.)

## How to Help Users Find Skills

### Step 1: Understand What They Need

When a user asks for help with something, identify:

1. The domain (e.g., React, testing, design, deployment)
2. The specific task (e.g., writing tests, creating animations, reviewing PRs)
3. Whether this is a common enough task that a skill likely exists

### Step 2: Search Both Marketplaces

Always search **both** marketplaces in parallel for the best results:

**skillhu.bz** (search by keyword, optionally filter by category or tag):
```bash
npx skillhu search [query]
npx skillhu search [query] --category [category]
npx skillhu search [query] --tag [tag]
```

Categories: development, devops, data, content, creative, marketing, sales, operations, research, communication, integrations, productivity, testing, security, utilities

**skills.sh** (search by keyword):
```bash
npx skills find [query]
```

Run both searches in parallel and combine the results.

### Step 3: Present Options to the User

When you find relevant skills, present a combined list from both sources:

```
I found these skills:

From skillhu.bz:
  pdf-toolkit v1.0.0 by anthropic
  Comprehensive PDF manipulation toolkit
  Install: npx skillhu install pdf-toolkit

From skills.sh:
  vercel-labs/agent-skills@vercel-react-best-practices
  React and Next.js performance optimization
  Install: npx skills add vercel-labs/agent-skills@vercel-react-best-practices
```

If both marketplaces return the same skill, mention it once and show both install options.

### Step 4: Install for the User

When the user picks a skill, install it:

**From skillhu.bz:**
```bash
npx skillhu install <skill-name>
```
Installs to `~/.claude/commands/` by default. Use `--local` for project-level.

**From skills.sh:**
```bash
npx skills add <owner/repo@skill> -g -y
```
The `-g` flag installs globally (user-level) and `-y` skips confirmation prompts.

### Step 5: Verify Installation

After installing, confirm the skill is available:
```bash
ls ~/.claude/skills/*/SKILL.md ~/.claude/commands/*/SKILL.md 2>/dev/null
```

## Browsing Skills

Users can also browse the full catalogs:

- **skillhu.bz**: `npx skillhu browse` (opens in browser) or visit https://skillhu.bz
- **skills.sh**: Visit https://skills.sh/

List already-installed skills:
```bash
npx skillhu list
```

## Updating Skills

Check for and apply updates:
```bash
npx skills check    # check for updates (skills.sh)
npx skills update   # update all (skills.sh)
```

## Common Skill Categories

When searching, consider these common categories:

| Category        | Example Queries                          |
| --------------- | ---------------------------------------- |
| Web Development | react, nextjs, typescript, css, tailwind |
| Testing         | testing, jest, playwright, e2e           |
| DevOps          | deploy, docker, kubernetes, ci-cd        |
| Documentation   | docs, readme, changelog, api-docs        |
| Code Quality    | review, lint, refactor, best-practices   |
| Design          | ui, ux, design-system, accessibility     |
| Productivity    | workflow, automation, git                |
| Creative        | art, image, slides, poster               |
| Data            | pdf, spreadsheet, csv, analysis          |

## Tips for Effective Searches

1. **Search both marketplaces** — they have different skill catalogs
2. **Use specific keywords**: "react testing" is better than just "testing"
3. **Try alternative terms**: If "deploy" doesn't work, try "deployment" or "ci-cd"
4. **Filter by category** on skillhu.bz for broader discovery: `npx skillhu search "" --category creative`

## When No Skills Are Found

If no relevant skills exist on either marketplace:

1. Acknowledge that no existing skill was found
2. Offer to help with the task directly using your general capabilities
3. Suggest the user could create their own skill:
   - `npx skillhu init my-skill` (for skillhu.bz)
   - `npx skills init my-skill` (for skills.sh)
