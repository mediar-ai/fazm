#!/usr/bin/env node
/**
 * cron-runner.mjs — runs ONE Fazm routine to completion via the ACP bridge.
 *
 * Invocation (from launchd polling script):
 *   node cron-runner.mjs --user-db <path-to-fazm.db> --job-id <uuid>
 *
 * What it does:
 *   1. Reads the cron_jobs row for <job-id>
 *   2. Inserts a "running" cron_runs row + a "user" chat_messages row (so the
 *      prompt shows up in conversation history while the agent is still working)
 *   3. Spawns the bridge subprocess (same way Swift does: `node dist/index.js`)
 *   4. Sends warmup → query JSON-line messages
 *   5. Captures the first `{"type":"result"}` line, extracts text + cost + tokens
 *   6. Writes the assistant chat_messages row, updates cron_runs.status=ok,
 *      and recomputes the job's next_run_at
 *
 * Exit codes:
 *   0 — success
 *   1 — generic error (logged to cron_runs.error_message)
 *   2 — bad arguments / job not found
 *
 * No external SQLite library — shells out to /usr/bin/sqlite3 with -json.
 * No network calls beyond what the bridge itself does.
 */

import { spawn, execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { existsSync, mkdirSync, appendFileSync, realpathSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { computeNextRun } from "./schedule.mjs";

export { computeNextRun };

const __dirname = dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------- args + log

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const val = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : "true";
      out[key] = val;
    }
  }
  return out;
}

// Robust "am I the entrypoint?" check. The naive
// `import.meta.url === \`file://${process.argv[1]}\`` breaks whenever the path holds a
// character import.meta.url percent-encodes — notably the space in "Fazm Dev.app", which
// becomes %20 while process.argv[1] keeps a literal space — so main() silently never runs
// and the routine exits 0 having done nothing. Decode the URL to a real path and resolve
// symlinks on both sides before comparing.
function resolvePathSafe(p) {
  try { return realpathSync(p); } catch { return p; }
}
const isMain = process.argv[1] != null &&
  resolvePathSafe(fileURLToPath(import.meta.url)) === resolvePathSafe(process.argv[1]);
const args = isMain ? parseArgs(process.argv.slice(2)) : {};
const USER_DB = args["user-db"];
const JOB_ID = args["job-id"];
const TIMEOUT_SEC = parseInt(args["timeout"] || "600", 10); // 10 min default

if (isMain && (!USER_DB || !JOB_ID)) {
  console.error("Usage: cron-runner.mjs --user-db <path> --job-id <uuid> [--timeout <sec>]");
  process.exit(2);
}

// Log dir resolution. The in-app scheduler (RoutineScheduler.swift) passes
// FAZM_ROUTINE_LOG_DIR (under Application Support) so we never create a ~/fazm tree
// on a normal user's machine. The dev launchd pipeline sets nothing and has the
// ~/fazm/inbox/skill checkout, so it keeps logging there. Anything else (e.g. a
// stray manual run) falls back to the OS temp dir.
const LOG_DIR = process.env.FAZM_ROUTINE_LOG_DIR
  || (existsSync(join(homedir(), "fazm", "inbox", "skill"))
        ? join(homedir(), "fazm", "inbox", "skill", "logs")
        : join(tmpdir(), "fazm-routines"));
try { mkdirSync(LOG_DIR, { recursive: true }); } catch {}
const LOG_FILE = join(LOG_DIR, "routines.log");

function log(msg) {
  const line = `[${new Date().toISOString()}] [${JOB_ID.slice(0, 8)}] ${msg}\n`;
  try { appendFileSync(LOG_FILE, line); } catch {}
  process.stderr.write(line);
}

// ---------------------------------------------------------------- sqlite

const SQLITE_BIN = "/usr/bin/sqlite3";

function buildScript(query, params, mode = "json") {
  // NOTE: do NOT include PRAGMA statements here in JSON mode — sqlite3 prints
  // their result (e.g. `[{"timeout":5000}]`) on stdout, which would concatenate
  // with the real query result and break JSON.parse. Use `-cmd ".timeout N"`
  // CLI flag instead (silent).
  const cmds = [`.mode ${mode}`];
  for (let i = 0; i < params.length; i++) {
    cmds.push(`.param set :p${i} ${sqliteValue(params[i])}`);
  }
  let idx = 0;
  const finalQuery = query.replace(/\?/g, () => `:p${idx++}`);
  cmds.push(finalQuery);
  return cmds.join("\n") + "\n";
}

const SQLITE_ARGS = ["-cmd", ".timeout 5000", USER_DB];

function sql(query, params = []) {
  try {
    const out = execFileSync(SQLITE_BIN, SQLITE_ARGS, {
      input: buildScript(query, params, "json"),
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
    if (!out.trim()) return [];
    return JSON.parse(out);
  } catch (err) {
    log(`SQL error: ${err.message} (query=${query.slice(0, 100)})`);
    throw err;
  }
}

function sqliteValue(v) {
  if (v === null || v === undefined) return "NULL";
  if (typeof v === "number") return String(v);
  if (typeof v === "boolean") return v ? "1" : "0";
  // String — escape single quotes and wrap
  return `'${String(v).replace(/'/g, "''")}'`;
}

function exec(query, params = []) {
  try {
    execFileSync(SQLITE_BIN, SQLITE_ARGS, {
      input: buildScript(query, params, "list"),
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (err) {
    log(`SQL exec error: ${err.message} (query=${query.slice(0, 100)})`);
    throw err;
  }
}

// ---------------------------------------------------------------- bridge spawn

function findBridgeEntry() {
  // Prefer the dist build colocated with this file (acp-bridge/dist/index.js).
  const candidates = [
    join(__dirname, "..", "dist", "index.js"),
    join(__dirname, "..", "..", "acp-bridge", "dist", "index.js"),
    join(homedir(), "fazm", "acp-bridge", "dist", "index.js"),
  ];
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  throw new Error(
    `acp-bridge dist/index.js not found. Tried: ${candidates.join(", ")}. Run \`./run.sh\` once to build it.`
  );
}

function runBridge(job, timeoutSec) {
  return new Promise((resolveP, rejectP) => {
    const bridgePath = findBridgeEntry();
    log(`Spawning bridge: ${bridgePath}`);

    const env = { ...process.env };
    delete env.CLAUDECODE; // Same as Swift does — avoid nested-session guard
    env.NODE_NO_WARNINGS = "1";
    // Tell fazm-tools-stdio that this is a headless cron run, not a UI session.
    // Used by tools that would otherwise pop up a UI confirm (cron has no UI).
    env.FAZM_HEADLESS = "1";
    env.FAZM_QUERY_MODE = "act";

    const proc = spawn(process.execPath, [
      "--max-old-space-size=512",
      bridgePath,
    ], {
      env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    let stdoutBuf = "";
    let resultMsg = null;
    let initSeen = false;
    let queryId = randomUUID();
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      log(`Timeout after ${timeoutSec}s — killing bridge`);
      try { proc.kill("SIGKILL"); } catch {}
    }, timeoutSec * 1000);

    proc.stdout.on("data", (chunk) => {
      stdoutBuf += chunk.toString();
      let nl;
      while ((nl = stdoutBuf.indexOf("\n")) >= 0) {
        const line = stdoutBuf.slice(0, nl);
        stdoutBuf = stdoutBuf.slice(nl + 1);
        if (!line.trim()) continue;
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }
        if (msg.type === "init" && !initSeen) {
          initSeen = true;
          log("Bridge init received, sending warmup + query");
          // Send warmup with our session config
          const warmupKey = job.session_mode === "resume" && job.acp_session_id
            ? `routine-${job.id}`
            : `routine-${job.id}-${Date.now()}`;
          const warmup = {
            type: "warmup",
            cwd: job.workspace || homedir(),
            sessions: [{
              key: warmupKey,
              model: job.model || "claude-sonnet-4-6",
              systemPrompt: undefined,
              resume: job.session_mode === "resume" ? (job.acp_session_id || undefined) : undefined,
            }],
          };
          proc.stdin.write(JSON.stringify(warmup) + "\n");
          // Then the query
          const query = {
            type: "query",
            id: queryId,
            prompt: job.prompt,
            systemPrompt: "",
            sessionKey: warmupKey,
            cwd: job.workspace || homedir(),
            mode: "act",
            model: job.model || "claude-sonnet-4-6",
          };
          proc.stdin.write(JSON.stringify(query) + "\n");
        } else if (msg.type === "result") {
          resultMsg = msg;
          // We have what we need — shut down
          clearTimeout(timer);
          try { proc.kill("SIGTERM"); } catch {}
        } else if (msg.type === "error") {
          log(`Bridge error: ${msg.message || JSON.stringify(msg)}`);
        } else if (msg.type === "authRequired") {
          log("Bridge requires auth — aborting cron run");
          clearTimeout(timer);
          try { proc.kill("SIGTERM"); } catch {}
          rejectP(new Error("Bridge auth required — sign in to Fazm and try again"));
          return;
        }
      }
    });

    proc.stderr.on("data", (chunk) => {
      // Only log first 500 chars per chunk to avoid filling disk on chatty output
      const s = chunk.toString();
      log(`bridge.stderr: ${s.slice(0, 500).trim()}`);
    });

    proc.on("close", (code) => {
      clearTimeout(timer);
      if (timedOut) {
        rejectP(new Error(`Bridge timed out after ${timeoutSec}s`));
        return;
      }
      if (resultMsg) {
        resolveP(resultMsg);
      } else {
        rejectP(new Error(`Bridge exited (code=${code}) before producing a result`));
      }
    });

    proc.on("error", (err) => {
      clearTimeout(timer);
      rejectP(err);
    });
  });
}

// ---------------------------------------------------------------- main

async function main() {
  if (!existsSync(USER_DB)) {
    log(`User DB not found: ${USER_DB}`);
    process.exit(2);
  }

  // Load the job
  const rows = sql("SELECT * FROM cron_jobs WHERE id = ? AND enabled = 1", [JOB_ID]);
  if (rows.length === 0) {
    log(`Job ${JOB_ID} not found or disabled`);
    process.exit(2);
  }
  const job = rows[0];
  log(`Running routine "${job.name}" — schedule=${job.schedule}, model=${job.model || "default"}`);

  const startedAt = Date.now() / 1000;
  const userMessageId = randomUUID();
  const conversationKey = `routine-${job.id}`;

  // Insert "running" run row + the user-side chat message right away so the
  // UI can show the prompt while the agent is still working.
  exec(`
    INSERT INTO cron_runs (job_id, started_at, status)
    VALUES (?, ?, 'running')
  `, [JOB_ID, startedAt]);

  exec(`
    INSERT OR IGNORE INTO chat_messages
      (taskId, messageId, sender, messageText, createdAt, updatedAt, backendSynced, session_id)
    VALUES (?, ?, 'user', ?, ?, ?, 0, ?)
  `, [conversationKey, userMessageId, job.prompt, startedAt, startedAt, job.acp_session_id || null]);

  let result;
  let errorMessage = null;
  let runStatus = "ok";

  try {
    result = await runBridge(job, TIMEOUT_SEC);
  } catch (err) {
    errorMessage = err.message || String(err);
    runStatus = errorMessage.toLowerCase().includes("timed out") ? "timeout" : "error";
    log(`Run failed: ${errorMessage}`);
  }

  const finishedAt = Date.now() / 1000;
  const durationMs = Math.round((finishedAt - startedAt) * 1000);

  // Persist result
  if (result && result.text) {
    const assistantMessageId = randomUUID();
    exec(`
      INSERT OR IGNORE INTO chat_messages
        (taskId, messageId, sender, messageText, createdAt, updatedAt, backendSynced, session_id)
      VALUES (?, ?, 'ai', ?, ?, ?, 0, ?)
    `, [conversationKey, assistantMessageId, result.text, finishedAt, finishedAt, result.sessionId || null]);

    exec(`
      UPDATE cron_runs
      SET finished_at = ?, status = ?, output_text = ?, cost_usd = ?,
          input_tokens = ?, output_tokens = ?, duration_ms = ?, chat_message_id = ?
      WHERE id = (SELECT MAX(id) FROM cron_runs WHERE job_id = ?)
    `, [
      finishedAt, runStatus, result.text,
      result.costUsd ?? null, result.inputTokens ?? null, result.outputTokens ?? null,
      durationMs, assistantMessageId, JOB_ID,
    ]);
  } else {
    // Bridge returned but no assistant text (e.g. model end_turn'd after thinking only,
    // or stopped on a tool call without a final reply). Don't claim status='ok' — the
    // routine produced no output the user can read, and the <routines> briefing should
    // surface it as a failure so the agent notices and the user can fix the prompt.
    if (runStatus === "ok") runStatus = "error";
    exec(`
      UPDATE cron_runs
      SET finished_at = ?, status = ?, error_message = ?, duration_ms = ?
      WHERE id = (SELECT MAX(id) FROM cron_runs WHERE job_id = ?)
    `, [finishedAt, runStatus, errorMessage || "no result", durationMs, JOB_ID]);
  }

  // Update job: last_run_at, last_status, recompute next_run_at, persist sessionId
  const nextRun = computeNextRun(job.schedule, new Date(finishedAt * 1000));
  const sessionIdToPersist = result?.sessionId && job.session_mode === "resume"
    ? result.sessionId
    : job.acp_session_id;

  exec(`
    UPDATE cron_jobs
    SET last_run_at = ?, last_status = ?, last_error = ?,
        next_run_at = ?, run_count = run_count + 1, acp_session_id = ?,
        updated_at = ?
    WHERE id = ?
  `, [
    finishedAt, runStatus, errorMessage,
    nextRun ? nextRun.getTime() / 1000 : null,
    sessionIdToPersist,
    finishedAt,
    JOB_ID,
  ]);

  log(`Done — status=${runStatus}, cost=$${(result?.costUsd ?? 0).toFixed(4)}, next=${nextRun?.toISOString() || "never"}`);
  process.exit(runStatus === "ok" ? 0 : 1);
}

if (isMain) {
  main().catch((err) => {
    log(`Fatal: ${err.stack || err.message || err}`);
    process.exit(1);
  });
}
