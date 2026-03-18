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
import { readFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";

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
      reject(err);
    });
  });
}

async function requestSwiftTool(
  name: string,
  input: Record<string, unknown>
): Promise<string> {
  const callId = nextCallId();

  if (!pipeConnection) {
    return "Error: not connected to bridge";
  }

  return new Promise<string>((resolve) => {
    pendingToolCalls.set(callId, { resolve });
    const msg = JSON.stringify({ type: "tool_use", callId, name, input });
    pipeConnection!.write(msg + "\n");
  });
}

// --- MCP tool definitions ---

const isOnboarding = (process.env.FAZM_ONBOARDING || process.env.OMI_ONBOARDING) === "true";
const isObserver = process.env.FAZM_OBSERVER === "true";

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
  "ask_followup",
  "complete_onboarding",
  "save_knowledge_graph",
]);

// Observer session only gets these tools (KG, SQL, screenshots, skills)
const OBSERVER_TOOL_NAMES = new Set([
  "execute_sql",
  "save_knowledge_graph",
  "capture_screenshot",
  "load_skill",
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
      },
      required: ["query"],
    },
  },
  {
    name: "complete_task",
    description: `Toggle a task's completion status. Syncs to backend (Firestore).
Pass the task's backendId.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        task_id: {
          type: "string" as const,
          description: "The task's backendId",
        },
      },
      required: ["task_id"],
    },
  },
  {
    name: "delete_task",
    description: `Delete a task permanently. Syncs to backend (Firestore).
Pass the task's backendId.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        task_id: {
          type: "string" as const,
          description: "The task's backendId",
        },
      },
      required: ["task_id"],
    },
  },
  {
    name: "load_skill",
    description: `Load the full instructions for a named skill. Call this when you decide to use a skill listed in <available_skills>. Returns the complete SKILL.md content with step-by-step instructions and workflows.`,
    inputSchema: {
      type: "object" as const,
      properties: {
        name: {
          type: "string" as const,
          description: "Skill name exactly as listed in available_skills",
        },
      },
      required: ["name"],
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
    description: `Extract user identity from browser data (autofill, logins, history, bookmarks). Returns a markdown profile: name, emails, phones, addresses, payment info, accounts, top tools, contacts. Extracted locally from browser SQLite files — nothing leaves the machine. Auto-installs ai-browser-profile if not present (~10s install, ~10s extraction). Call BEFORE scan_files in onboarding.`,
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
];

// Filter tools based on session type:
// - onboarding: all tools
// - observer: only observer-specific tools (KG, SQL, screenshots, skills)
// - regular: all tools except onboarding-only tools
const TOOLS = ALL_TOOLS.filter((t) =>
  isOnboarding ? true
  : isObserver ? OBSERVER_TOOL_NAMES.has(t.name)
  : !ONBOARDING_TOOL_NAMES.has(t.name)
);

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

        // Observer mode: writes require user approval — store as pending card
        if (isObserver && isWriteQuery) {
          // Don't intercept observer_activity INSERTs (that's how the observer creates cards)
          const isObserverActivityWrite = normalized.includes("OBSERVER_ACTIVITY");
          if (!isObserverActivityWrite) {
            // Store the pending write operation in an approval card
            const cardContent = JSON.stringify({
              title: "Observer wants to update",
              body: describeSqlWrite(query),
              pending_operations: [{ tool: "execute_sql", args: { query } }],
              buttons: [
                { label: "Approve", action: "approve" },
                { label: "Dismiss", action: "dismiss" },
              ],
            });
            const insertCard = `INSERT INTO observer_activity (id, type, content, status, createdAt) VALUES (abs(random()), 'approval_request', '${cardContent.replace(/'/g, "''")}', 'pending', datetime('now'))`;
            await requestSwiftTool("execute_sql", { query: insertCard });
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
      } else if (toolName === "complete_task") {
        const taskId = args.task_id as string;
        const result = await requestSwiftTool("complete_task", { task_id: taskId });
        if (!isNotification) {
          send({
            jsonrpc: "2.0",
            id,
            result: { content: [{ type: "text", text: result }] },
          });
        }
      } else if (toolName === "delete_task") {
        const taskId = args.task_id as string;
        const result = await requestSwiftTool("delete_task", { task_id: taskId });
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
      } else if (toolName === "load_skill") {
        const name = (args.name as string || "").trim();
        logErr(`load_skill: resolving '${name}'`);
        const workspace = process.env.FAZM_WORKSPACE || process.env.OMI_WORKSPACE || "";
        // Resolve app bundle's BundledSkills directory
        // At runtime: __dirname = Contents/Resources/acp-bridge/dist/
        // BundledSkills = Contents/Resources/Fazm_Fazm.bundle/BundledSkills/
        const bundledSkillsDir = join(__dirname, "..", "..", "Fazm_Fazm.bundle", "BundledSkills");
        const candidates = [
          workspace ? join(workspace, ".claude", "skills", name, "SKILL.md") : "",
          join(homedir(), ".claude", "skills", name, "SKILL.md"),
          join(bundledSkillsDir, `${name}.skill.md`),
        ].filter(Boolean);

        let content: string | null = null;
        for (const filePath of candidates) {
          try {
            content = readFileSync(filePath, "utf8");
            logErr(`load_skill: loaded '${name}' from ${filePath} (${content.length} bytes)`);
            break;
          } catch {
            // not at this path, try next
          }
        }

        if (!content) {
          logErr(`load_skill: '${name}' not found in any candidate path`);
        }

        // For dev-mode, prepend workspace path so Claude has that context
        if (content && name === "dev-mode" && workspace) {
          content = `Workspace: ${workspace}\n\n${content}`;
        }

        if (!isNotification) {
          logErr(`load_skill: sending response for '${name}'`);
          send({
            jsonrpc: "2.0",
            id,
            result: {
              content: [{
                type: "text",
                text: content ?? `Skill '${name}' not found. Check the name matches one listed in <available_skills>.`,
              }],
            },
          });
        }
      } else if (isObserver && toolName === "save_knowledge_graph") {
        // Observer mode: KG writes require user approval
        const nodes = (args.nodes as Array<Record<string, unknown>>) || [];
        const edges = (args.edges as Array<Record<string, unknown>>) || [];
        const nodesSummary = nodes.map((n: Record<string, unknown>) => `${n.name} (${n.type})`).join(", ");
        const edgesSummary = edges.map((e: Record<string, unknown>) => `${e.source} → ${e.target} (${e.relation})`).join(", ");
        const body = `Save to knowledge graph:\n• Nodes: ${nodesSummary || "none"}\n• Edges: ${edgesSummary || "none"}`;
        const cardContent = JSON.stringify({
          title: "Observer wants to update knowledge graph",
          body,
          pending_operations: [{ tool: "save_knowledge_graph", args }],
          buttons: [
            { label: "Approve", action: "approve" },
            { label: "Dismiss", action: "dismiss" },
          ],
        });
        const insertCard = `INSERT INTO observer_activity (id, type, content, status, createdAt) VALUES (abs(random()), 'approval_request', '${cardContent.replace(/'/g, "''")}', 'pending', datetime('now'))`;
        await requestSwiftTool("execute_sql", { query: insertCard });
        if (!isNotification) {
          send({
            jsonrpc: "2.0",
            id,
            result: {
              content: [
                {
                  type: "text",
                  text: "Knowledge graph update queued for user approval. A card has been shown to the user. Continue with other tasks — do NOT retry this write.",
                },
              ],
            },
          });
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
