/**
 * Stdio-based MCP server for Fazm tools (execute_sql, complete_task, etc.).
 * This script is spawned as a subprocess by the ACP agent.
 * It reads JSON-RPC requests from stdin and writes responses to stdout.
 *
 * Tool calls are forwarded to the parent acp-bridge process via a named pipe
 * (passed as FAZM_BRIDGE_PIPE env var), which then forwards them to Swift.
 */

import { createInterface } from "readline";
import { createConnection } from "net";

// Current query mode
let currentMode: "ask" | "act" = (process.env.FAZM_QUERY_MODE || process.env.OMI_QUERY_MODE) === "ask" ? "ask" : "act";

// Connection to parent bridge for tool forwarding
const bridgePipePath = process.env.FAZM_BRIDGE_PIPE || process.env.OMI_BRIDGE_PIPE;

// Pending tool calls — resolved when parent sends back results via pipe
const pendingToolCalls = new Map<
  string,
  { resolve: (result: string) => void }
>();

let callIdCounter = 0;

function nextCallId(): string {
  return `fazm-${++callIdCounter}-${Date.now()}`;
}

function logErr(msg: string): void {
  // Route through bridge pipe so logs appear in the app log.
  // Falls back to stderr before pipe is connected.
  if (pipeConnection) {
    try {
      pipeConnection.write(JSON.stringify({ type: "log", message: msg }) + "\n");
    } catch {
      process.stderr.write(`[fazm-tools-stdio] ${msg}\n`);
    }
  } else {
    process.stderr.write(`[fazm-tools-stdio] ${msg}\n`);
  }
}

// --- Communication with parent bridge ---

let pipeConnection: ReturnType<typeof createConnection> | null = null;
let pipeBuffer = "";

function connectToPipe(): Promise<void> {
  return new Promise((resolve, reject) => {
    if (!bridgePipePath) {
      logErr("No FAZM_BRIDGE_PIPE set, tool calls will fail");
      resolve();
      return;
    }

    pipeConnection = createConnection(bridgePipePath, () => {
      logErr(`Connected to bridge pipe: ${bridgePipePath}`);
      pipeConnected = true;
      resolve();
    });

    pipeConnection.on("data", (data: Buffer) => {
      pipeBuffer += data.toString();
      // Process complete lines
      let newlineIdx;
      while ((newlineIdx = pipeBuffer.indexOf("\n")) >= 0) {
        const line = pipeBuffer.slice(0, newlineIdx);
        pipeBuffer = pipeBuffer.slice(newlineIdx + 1);
        if (line.trim()) {
          try {
            const msg = JSON.parse(line) as {
              type: string;
              callId: string;
              result: string;
            };
            if (msg.type === "tool_result" && msg.callId) {
              const pending = pendingToolCalls.get(msg.callId);
              if (pending) {
                pending.resolve(msg.result);
                pendingToolCalls.delete(msg.callId);
              }
            }
          } catch {
            logErr(`Failed to parse pipe message: ${line.slice(0, 200)}`);
          }
        }
      }
    });

    pipeConnection.on("error", (err) => {
      logErr(`Pipe error: ${err.message}`);
      // Reject only during initial connection; after that, mark pipe dead
      if (pipeConnected) {
        pipeConnection = null;
        rejectPendingToolCalls("bridge pipe error");
      } else {
        reject(err);
      }
    });

    pipeConnection.on("close", () => {
      logErr("Bridge pipe closed");
      pipeConnection = null;
      rejectPendingToolCalls("bridge pipe closed");
    });

    pipeConnection.on("end", () => {
      logErr("Bridge pipe ended");
      pipeConnection = null;
      rejectPendingToolCalls("bridge pipe ended");
    });
  });
}

let pipeConnected = false;

/** Reject all pending tool calls (pipe died) */
function rejectPendingToolCalls(reason: string): void {
  for (const [callId, pending] of pendingToolCalls) {
    logErr(`Rejecting pending tool call ${callId}: ${reason}`);
    pending.resolve(`Error: ${reason}`);
  }
  pendingToolCalls.clear();
}

/** Notify the bridge that an observer card is ready for immediate display */
function notifyObserverCardReady(): void {
  if (pipeConnection) {
    try {
      pipeConnection.write(JSON.stringify({ type: "observer_card_ready" }) + "\n");
    } catch {
      logErr("Failed to send observer_card_ready notification");
    }
  }
}

const TOOL_TIMEOUT_MS = 30_000;

async function requestSwiftTool(
  name: string,
  input: Record<string, unknown>
): Promise<string> {
  const callId = nextCallId();

  if (!pipeConnection) {
    return "Error: not connected to bridge";
  }

  return new Promise<string>((resolve) => {
    const timer = setTimeout(() => {
      if (pendingToolCalls.has(callId)) {
        pendingToolCalls.delete(callId);
        logErr(`Tool call timed out after ${TOOL_TIMEOUT_MS}ms: ${name} (${callId})`);
        resolve(`Error: tool call timed out after ${TOOL_TIMEOUT_MS / 1000}s`);
      }
    }, TOOL_TIMEOUT_MS);

    pendingToolCalls.set(callId, {
      resolve: (result: string) => {
        clearTimeout(timer);
        resolve(result);
      },
    });
    const msg = JSON.stringify({ type: "tool_use", callId, name, input });
    pipeConnection!.write(msg + "\n");
  });
}

// --- MCP tool definitions ---

const isOnboarding = (process.env.FAZM_ONBOARDING || process.env.OMI_ONBOARDING) === "true";
const isObserver = process.env.FAZM_OBSERVER === "true";
const isVoiceResponseEnabled = process.env.FAZM_VOICE_RESPONSE === "true";

/** Escape a string for use inside a SQL single-quoted literal.
 *  Handles both single quotes (doubled for SQL) and ensures the
 *  result is safe for embedding in a SQL string.  */
function sqlStringEscape(s: string): string {
  // Replace single quotes with doubled single quotes (SQL standard escaping)
  return s.replace(/'/g, "''");
}

/** Build a safe INSERT for observer_activity with JSON content.
 *  Uses X'...' hex literal to avoid all quoting issues with embedded JSON. */
function buildObserverInsert(type: string, contentObj: Record<string, unknown>): string {
  const json = JSON.stringify(contentObj);
  const hex = Buffer.from(json, "utf-8").toString("hex");
  return `INSERT INTO observer_activity (id, type, content, status, createdAt) VALUES (abs(random()), '${type}', X'${hex}', 'pending', datetime('now'))`;
}

/** Extract the card type from an observer_activity INSERT (e.g. 'insight', 'summary', 'skill_draft') */
function extractObserverCardType(query: string): string | null {
  // Match: VALUES (abs(random()), 'TYPE', ...
  const match = query.match(/VALUES\s*\([^,]+,\s*'([^']+)'/i);
  return match?.[1] || null;
}

/** Extract the JSON content object from an observer_activity INSERT.
 *  The observer writes raw JSON in the SQL — we parse it out and return as an object.
 *  Falls back to wrapping the raw content string in a {body:...} object. */
function extractObserverCardContent(query: string): Record<string, unknown> {
  // The content is the 3rd VALUES field — find it by matching after type
  // Pattern: VALUES(id, 'type', 'JSON_CONTENT', 'status', ...)
  // The JSON is single-quoted with doubled single quotes for escaping
  const afterType = query.match(/VALUES\s*\([^,]+,\s*'[^']+',\s*'/i);
  if (afterType) {
    const startIdx = (afterType.index ?? 0) + afterType[0].length;
    // Walk forward to find the closing quote (not doubled)
    let depth = 0;
    let i = startIdx;
    let content = "";
    while (i < query.length) {
      if (query[i] === "'" && query[i + 1] === "'") {
        content += "'";
        i += 2;
      } else if (query[i] === "'") {
        break;
      } else {
        content += query[i];
        i++;
      }
    }
    try {
      return JSON.parse(content) as Record<string, unknown>;
    } catch {
      return { body: content };
    }
  }
  return { body: "Observer update" };
}

/** Human-readable summary of a write SQL query for approval cards */
function describeSqlWrite(query: string): string {
  const trimmed = query.trim();
  const upper = trimmed.toUpperCase();
  if (upper.startsWith("INSERT")) {
    const tableMatch = trimmed.match(/INSERT\s+INTO\s+(\w+)/i);
    const table = tableMatch?.[1] || "unknown table";
    return `Insert into ${table}:\n${trimmed.substring(0, 500)}${trimmed.length > 500 ? "..." : ""}`;
  } else if (upper.startsWith("UPDATE")) {
    const tableMatch = trimmed.match(/UPDATE\s+(\w+)/i);
    const table = tableMatch?.[1] || "unknown table";
    return `Update ${table}:\n${trimmed.substring(0, 500)}${trimmed.length > 500 ? "..." : ""}`;
  } else if (upper.startsWith("DELETE")) {
    const tableMatch = trimmed.match(/DELETE\s+FROM\s+(\w+)/i);
    const table = tableMatch?.[1] || "unknown table";
    return `Delete from ${table}:\n${trimmed.substring(0, 500)}${trimmed.length > 500 ? "..." : ""}`;
  }
  return trimmed.substring(0, 500);
}

const ONBOARDING_TOOL_NAMES = new Set([
  "check_permission_status",
  "request_permission",
  "extract_browser_profile",
  "scan_files",
  "set_user_preferences",
  "complete_onboarding",
  "save_knowledge_graph",
]);

// Tools available in all sessions (not just onboarding)
const ALWAYS_AVAILABLE_TOOL_NAMES = new Set([
  "extract_browser_profile",
  "ask_followup",
]);

// Observer session only gets these tools (SQL reads, screenshots, skills, browser profile, cards)
const OBSERVER_TOOL_NAMES = new Set([
  "execute_sql",
  "capture_screenshot",
  "query_browser_profile",
  "edit_browser_profile",
  "save_observer_card",
]);

const ALL_TOOLS = [
  {
    name: "execute_sql",
    description: `Run SQL on the local fazm.db database.
Supports: SELECT, INSERT, UPDATE, DELETE.
SELECT auto-limits to 200 rows. UPDATE/DELETE require WHERE. DROP/ALTER/CREATE blocked.
Use for: app usage stats, time queries, task management, aggregations, anything structured.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        query: { type: "string" as const, description: "SQL query to execute" },
        description: { type: "string" as const, description: "Human-readable description of what this write does (used for observer approval cards)" },
      },
      required: ["query"],
    },
  },
  {
    name: "capture_screenshot",
    description: `Capture a screenshot of the user's screen and return it as a base64-encoded JPEG image.
Use for: "what's on my screen", "take a screenshot", "describe what you see", screen analysis.
Modes:
- "screen": Full screen capture (default)
- "window": Just the frontmost app window
This is the ONLY way to see what's on the user's desktop. Do NOT use playwright's browser_take_screenshot for this — that only captures the browser viewport.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        mode: {
          type: "string" as const,
          enum: ["screen", "window"],
          description: "Capture mode: 'screen' for full display, 'window' for active app window (default: screen)",
        },
      },
      required: [],
    },
  },
  // --- Onboarding tools ---
  {
    name: "check_permission_status",
    description: `Check which macOS permissions are currently granted. Returns JSON with status of all 5 permissions: screen_recording, microphone, notifications, accessibility, automation. Call before requesting permissions.`,
    inputSchema: {
      type: "object" as const,
      properties: {},
      required: [],
    },
  },
  {
    name: "request_permission",
    description: `Request a specific macOS permission from the user. Triggers the macOS system permission dialog. Returns "granted", "pending", or "denied". Call one at a time.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        type: {
          type: "string" as const,
          description:
            "Permission type: screen_recording, microphone, notifications, accessibility, or automation",
        },
      },
      required: ["type"],
    },
  },
  {
    name: "extract_browser_profile",
    description: `Extract user identity from browser data (autofill, logins, history, bookmarks). Returns a markdown profile: name, emails, phones, addresses, payment info, accounts, top tools, contacts. Extracted locally from browser SQLite files — nothing leaves the machine. Takes ~1-2 seconds. query_browser_profile auto-triggers this if the profile is missing, stale (>24h), or incomplete — but you can also call this directly to force a fresh extraction.`,
    inputSchema: {
      type: "object" as const,
      properties: {},
      required: [],
    },
  },
  {
    name: "edit_browser_profile",
    description: `Delete or update a specific entry in the user's browser profile database. Use after showing the profile summary to apply corrections the user requests. For delete: finds memories matching the query and removes them. For update: finds the matching memory and sets a new value.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        action: { type: "string" as const, enum: ["delete", "update"], description: "Whether to delete or update the matched memory" },
        query: { type: "string" as const, description: "Text to search for in the memory value, e.g. '+33 6 48 14 07 38' or 'french phone'" },
        new_value: { type: "string" as const, description: "For update only: the replacement value" },
      },
      required: ["action", "query"],
    },
  },
  {
    name: "query_browser_profile",
    description: `Search the user's locally-extracted browser profile (identity, accounts, tools, contacts, addresses, payments). Use when the user asks about themselves or you need personal context. Data comes from browser autofill, saved logins, history, and bookmarks — extracted locally, nothing leaves the machine.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        query: { type: "string" as const, description: "Natural language query, e.g. 'email address', 'full profile', 'GitHub account'" },
        tags: { type: "array" as const, items: { type: "string" as const }, description: "Optional tag filters: identity, contact_info, account, tool, address, payment, contact, work, knowledge" },
      },
      required: ["query"],
    },
  },
  {
    name: "scan_files",
    description: `Scan the user's files. BLOCKING — waits for the scan to complete before returning. Scans ~/Downloads, ~/Documents, ~/Desktop, ~/Developer, ~/Projects, /Applications. Returns file type breakdown, project indicators, recent files, installed apps. Also reports which folders were DENIED access by macOS. If folders were denied, call again after the user grants access.`,
    inputSchema: {
      type: "object" as const,
      properties: {},
      required: [],
    },
  },
  {
    name: "set_user_preferences",
    description: `Save user preferences like language and name. Only call if the user explicitly mentions a preferred language or name correction.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        language: {
          type: "string" as const,
          description: "Language code (e.g. en, es, ja)",
        },
        name: {
          type: "string" as const,
          description: "User's preferred name",
        },
      },
      required: [],
    },
  },
  {
    name: "ask_followup",
    description: `Present a question with quick-reply buttons to the user. The UI renders clickable buttons.
Use in Step 4 (follow-up question after file discoveries) and Step 5 (permission grant buttons).
The user can click a button OR type their own reply. Wait for their response before continuing.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        question: {
          type: "string" as const,
          description: "The question to present to the user",
        },
        options: {
          type: "array" as const,
          items: { type: "string" as const },
          description:
            "2-3 quick-reply button labels. For permissions, include 'Grant [Permission]' and 'Skip'.",
        },
      },
      required: ["question", "options"],
    },
  },
  {
    name: "complete_onboarding",
    description: `Finish onboarding and start the app. Logs analytics, starts background services, enables launch-at-login. Call as the LAST step after permissions are done.`,
    inputSchema: {
      type: "object" as const,
      properties: {},
      required: [],
    },
  },
  {
    name: "save_knowledge_graph",
    description: `Save a knowledge graph of entities and relationships discovered about the user.
Extract people, organizations, projects, tools, languages, frameworks, and concepts.
Build relationships like: works_on, uses, built_with, part_of, knows, etc.
Aim for 15-40 nodes with meaningful edges connecting them.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        nodes: {
          type: "array" as const,
          items: {
            type: "object" as const,
            properties: {
              id: { type: "string" as const },
              label: { type: "string" as const },
              node_type: {
                type: "string" as const,
                enum: ["person", "organization", "place", "thing", "concept"],
              },
              aliases: { type: "array" as const, items: { type: "string" as const } },
            },
            required: ["id", "label", "node_type"],
          },
        },
        edges: {
          type: "array" as const,
          items: {
            type: "object" as const,
            properties: {
              source_id: { type: "string" as const },
              target_id: { type: "string" as const },
              label: { type: "string" as const },
            },
            required: ["source_id", "target_id", "label"],
          },
        },
      },
      required: ["nodes", "edges"],
    },
  },
  {
    name: "save_observer_card",
    description: `Save an observer card to notify the user about something you observed. The card is saved immediately and the user can dismiss it to undo. Use this instead of writing raw SQL to observer_activity.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        body: { type: "string" as const, description: "The card text to show the user, e.g. 'Saved: user prefers dark mode'" },
        type: { type: "string" as const, enum: ["insight", "pattern", "skill_created", "kg_update"], description: "Card type (default: insight)" },
      },
      required: ["body"],
    },
  },
  {
    name: "speak_response",
    description: `Speak a short summary of your response aloud to the user using text-to-speech. Call this on EVERY final response when the conversation language is supported. The text should be a natural, conversational summary (1-3 sentences) — not the full written response. Keep it brief and direct, as if you're speaking to the user face-to-face. IMPORTANT: Only call this tool when the conversation is in one of these supported languages: English, Spanish, French, German, Italian, Dutch, Japanese. Do NOT call this tool for any other language (e.g. Russian, Chinese, Korean, Portuguese, Arabic, etc.) — the TTS engine cannot synthesize those languages and will produce garbled audio.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        text: {
          type: "string" as const,
          description: "The text to speak aloud. Keep it short and conversational (1-3 sentences).",
        },
      },
      required: ["text"],
    },
  },
];

// Tools gated behind the voice response toggle
const VOICE_RESPONSE_TOOL_NAMES = new Set(["speak_response"]);

// Filter tools based on session type:
// - onboarding: all tools (except voice-gated unless enabled)
// - observer: only observer-specific tools (KG, SQL, screenshots, skills)
// - regular: all tools except onboarding-only tools
// speak_response is only included when FAZM_VOICE_RESPONSE is enabled
const TOOLS = ALL_TOOLS.filter((t) => {
  // Gate voice response tools behind the toggle
  if (VOICE_RESPONSE_TOOL_NAMES.has(t.name) && !isVoiceResponseEnabled) return false;
  if (isOnboarding) return true;
  if (isObserver) return OBSERVER_TOOL_NAMES.has(t.name);
  // Some tools are available in all sessions even though they're also in onboarding
  if (ALWAYS_AVAILABLE_TOOL_NAMES.has(t.name)) return true;
  return !ONBOARDING_TOOL_NAMES.has(t.name);
});

// --- JSON-RPC handling ---

function send(msg: Record<string, unknown>): void {
  try {
    process.stdout.write(JSON.stringify(msg) + "\n");
  } catch (err) {
    logErr(`Failed to write to stdout: ${err}`);
  }
}

function sendErrorResponse(id: unknown, code: number, message: string): void {
  send({ jsonrpc: "2.0", id, error: { code, message } });
}

async function handleJsonRpc(
  body: Record<string, unknown>
): Promise<void> {
  const id = body.id;
  const method = body.method as string;
  const params = (body.params ?? {}) as Record<string, unknown>;

  // Notifications (no id) don't get responses
  const isNotification = id === undefined || id === null;

  switch (method) {
    case "initialize":
      if (!isNotification) {
        send({
          jsonrpc: "2.0",
          id,
          result: {
            protocolVersion: "2024-11-05",
            capabilities: { tools: {} },
            serverInfo: { name: "fazm-tools", version: "1.0.0" },
          },
        });
      }
      break;

    case "notifications/initialized":
      // No response needed
      break;

    case "tools/list":
      if (!isNotification) {
        send({
          jsonrpc: "2.0",
          id,
          result: { tools: TOOLS },
        });
      }
      break;

    case "tools/call": {
      const toolName = params.name as string;
      const args = (params.arguments ?? {}) as Record<string, unknown>;

      logErr(`Tool call received: ${toolName} (id=${body.id})`);

      if (toolName === "execute_sql") {
        const query = args.query as string;
        const normalized = query.trim().toUpperCase();
        const isWriteQuery = !normalized.startsWith("SELECT");

        if (currentMode === "ask" && isWriteQuery) {
            if (!isNotification) {
              send({
                jsonrpc: "2.0",
                id,
                result: {
                  content: [
                    {
                      type: "text",
                      text: "Blocked: Only SELECT queries are allowed in Ask mode.",
                    },
                  ],
                },
              });
            }
            return;
        }

        // Observer mode: intercept all writes
        if (isObserver && isWriteQuery) {
          // Block writes to non-existent tables (e.g. hallucinated tables
          // when the LLM falls back to execute_sql instead of using proper tools)
          const tableMatch = normalized.match(/INSERT\s+INTO\s+(\w+)/i) ||
                             normalized.match(/UPDATE\s+(\w+)/i);
          if (tableMatch) {
            const KNOWN_TABLES = new Set([
              "observer_activity", "ai_user_profiles", "chat_messages",
              "indexed_files", "local_kg_nodes", "local_kg_edges", "grdb_migrations",
            ]);
            const targetTable = tableMatch[1].toLowerCase();
            if (!KNOWN_TABLES.has(targetTable)) {
              if (!isNotification) {
                send({
                  jsonrpc: "2.0",
                  id,
                  result: {
                    content: [{
                      type: "text",
                      text: `Blocked: table "${targetTable}" does not exist in the app database. To save observations, use your file tools to write memory files or use save_observer_card instead — do NOT write raw SQL.`,
                    }],
                  },
                });
              }
              return;
            }
          }

          const isObserverActivityWrite = normalized.includes("OBSERVER_ACTIVITY");
          if (isObserverActivityWrite) {
            // Observer card INSERT — re-encode safely via hex to prevent SQL injection
            // from content containing SQL fragments like datetime('now')
            const cardType = extractObserverCardType(query) || "insight";
            const cardContent = extractObserverCardContent(query);
            const safeInsert = buildObserverInsert(cardType, cardContent);
            await requestSwiftTool("execute_sql", { query: safeInsert });
            notifyObserverCardReady();
            if (!isNotification) {
              send({
                jsonrpc: "2.0",
                id,
                result: { content: [{ type: "text", text: "Card created." }] },
              });
            }
            return;
          } else {
            // Non-observer_activity writes require user approval
            const observerDescription = args.description as string | undefined;
            const body = observerDescription || describeSqlWrite(query);
            const insertCard = buildObserverInsert("approval_request", {
              title: "Database update",
              body,
              pending_operations: [{ tool: "execute_sql", args: { query } }],
              buttons: [
                { label: "Approve", action: "approve" },
                { label: "Dismiss", action: "dismiss" },
              ],
            });
            await requestSwiftTool("execute_sql", { query: insertCard });
            notifyObserverCardReady();
            if (!isNotification) {
              send({
                jsonrpc: "2.0",
                id,
                result: {
                  content: [
                    {
                      type: "text",
                      text: "Write operation queued for user approval. A card has been shown to the user. Continue with other tasks — do NOT retry this write.",
                    },
                  ],
                },
              });
            }
            return;
          }
        }

        const result = await requestSwiftTool("execute_sql", { query });
        if (!isNotification) {
          send({
            jsonrpc: "2.0",
            id,
            result: { content: [{ type: "text", text: result }] },
          });
        }
      } else if (toolName === "capture_screenshot") {
        const mode = (args.mode as string) || "screen";
        const result = await requestSwiftTool("capture_screenshot", { mode });
        if (!isNotification) {
          // Result from Swift is base64 JPEG — return as image content
          if (result.startsWith("ERROR:")) {
            send({
              jsonrpc: "2.0",
              id,
              result: { content: [{ type: "text", text: result }] },
            });
          } else {
            send({
              jsonrpc: "2.0",
              id,
              result: {
                content: [
                  { type: "image", data: result, mimeType: "image/jpeg" },
                  { type: "text", text: `Screenshot captured (${mode} mode).` },
                ],
              },
            });
          }
        }
      } else if (
        toolName === "check_permission_status" ||
        toolName === "request_permission" ||
        toolName === "extract_browser_profile" ||
        toolName === "scan_files" ||
        toolName === "set_user_preferences" ||
        toolName === "ask_followup" ||
        toolName === "complete_onboarding" ||
        toolName === "save_knowledge_graph"
      ) {
        // Onboarding tools — forward directly to Swift
        const result = await requestSwiftTool(toolName, args);
        if (!isNotification) {
          send({
            jsonrpc: "2.0",
            id,
            result: { content: [{ type: "text", text: result }] },
          });
        }
      } else if (toolName === "save_observer_card") {
        // Observer card tool — safely insert via hex encoding
        const cardType = (args.type as string) || "insight";
        const cardBody = (args.body as string) || "Observer update";
        const safeInsert = buildObserverInsert(cardType, { body: cardBody });
        await requestSwiftTool("execute_sql", { query: safeInsert });
        notifyObserverCardReady();
        if (!isNotification) {
          send({
            jsonrpc: "2.0",
            id,
            result: { content: [{ type: "text", text: "Card created." }] },
          });
        }
      } else if (toolName === "speak_response") {
        // Voice response — forward to Swift for TTS playback
        const result = await requestSwiftTool("speak_response", args);
        if (!isNotification) {
          send({
            jsonrpc: "2.0",
            id,
            result: { content: [{ type: "text", text: result }] },
          });
        }
      } else if (toolName === "query_browser_profile" || toolName === "edit_browser_profile") {
        // Always-available tools — forward to Swift
        const result = await requestSwiftTool(toolName, args);
        if (!isNotification) {
          send({
            jsonrpc: "2.0",
            id,
            result: { content: [{ type: "text", text: result }] },
          });
        }
      } else if (!isNotification) {
        send({
          jsonrpc: "2.0",
          id,
          error: { code: -32601, message: `Unknown tool: ${toolName}` },
        });
      }

      logErr(`Tool call done: ${toolName} (id=${body.id})`);
      break;
    }

    default:
      if (!isNotification) {
        send({
          jsonrpc: "2.0",
          id,
          error: { code: -32601, message: `Method not found: ${method}` },
        });
      }
  }
}

// --- Main ---

async function main(): Promise<void> {
  // Connect to parent bridge pipe for tool forwarding
  await connectToPipe();

  // Read JSON-RPC from stdin
  const rl = createInterface({ input: process.stdin, terminal: false });

  rl.on("line", (line: string) => {
    if (!line.trim()) return;
    try {
      const msg = JSON.parse(line) as Record<string, unknown>;
      handleJsonRpc(msg).catch((err) => {
        logErr(`Error handling request: ${err}`);
        // Send error response so ACP doesn't hang waiting
        const id = msg.id;
        if (id !== undefined && id !== null) {
          sendErrorResponse(id, -32603, `Internal error: ${err}`);
        }
      });
    } catch {
      logErr(`Invalid JSON: ${line.slice(0, 200)}`);
    }
  });

  rl.on("close", () => {
    process.exit(0);
  });

  logErr("fazm-tools stdio MCP server started");
}

main().catch((err) => {
  logErr(`Fatal: ${err}`);
  process.exit(1);
});
