// JSON lines protocol between Swift app and Node.js ACP bridge
// Extended from agent-bridge protocol with authentication message types

// === Swift → Bridge (stdin) ===

export interface QueryAttachment {
  path: string;
  name: string;
  mimeType: string;
}

export interface PriorContextEntry {
  role: "user" | "assistant";
  text: string;
}

export interface QueryMessage {
  type: "query";
  id: string;
  prompt: string;
  systemPrompt: string;
  sessionKey?: string;
  cwd?: string;
  mode?: "ask" | "act";
  model?: string;
  resume?: string;
  attachments?: QueryAttachment[];
  /**
   * Recent local conversation history (most recent last). Consulted by the
   * bridge in two recovery paths:
   *   1. `session/resume` fails upstream → bridge creates a new session and
   *      prepends a transcript preamble so context is not silently lost.
   *   2. A prior turn returned empty text (poisoned ACP session) → bridge
   *      forces a new session via `_priorStuckSessionId` and replays history.
   * Sent by Swift on EVERY query (even without resume) so the bridge always
   * has a fallback if the upstream session vanishes mid-conversation.
   */
  priorContext?: PriorContextEntry[];
  /**
   * Internal field used for stuck-session recovery recursion. When the bridge
   * detects that a session/prompt resolved with empty text + end_turn (the
   * "poisoned session" pattern), it re-enters handleQuery with this set to
   * the dead sessionId so the recovery emits a session_expired event with
   * the correct old id and replays priorContext into a fresh session. Not
   * sent by Swift; only set by the bridge during recursion.
   */
  _priorStuckSessionId?: string;
}

export interface ToolResultMessage {
  type: "tool_result";
  callId: string;
  result: string;
}

export interface StopMessage {
  type: "stop";
}

export interface InterruptMessage {
  type: "interrupt";
  sessionKey?: string;  // target a specific session; omit to interrupt all
}

/** Swift tells the bridge which auth method the user chose */
export interface AuthenticateMessage {
  type: "authenticate";
  methodId: string;
}

export interface WarmupSessionConfig {
  key: string;
  model: string;
  systemPrompt?: string;
  resume?: string;  // if set, resume this session ID instead of creating a new one
}

/** Swift tells the bridge to pre-create an ACP session in the background */
export interface WarmupMessage {
  type: "warmup";
  cwd?: string;
  model?: string;       // backward compat
  models?: string[];    // backward compat
  sessions?: WarmupSessionConfig[];  // new: per-session config with system prompts
}

export interface ResetSessionMessage {
  type: "resetSession";
  sessionKey?: string;
}

export interface TransferSessionMessage {
  type: "transferSession";
  fromKey: string;
  toKey: string;
}

/** Diagnostic probe — initialize the codex-acp adapter and report agent + auth state. */
export interface CodexInitProbeMessage {
  type: "codex_init_probe";
}

export interface CancelAuthMessage {
  type: "cancel_auth";
}

export type InboundMessage =
  | QueryMessage
  | ToolResultMessage
  | StopMessage
  | InterruptMessage
  | AuthenticateMessage
  | WarmupMessage
  | ResetSessionMessage
  | TransferSessionMessage
  | CancelAuthMessage
  | CodexInitProbeMessage;

// === Bridge → Swift (stdout) ===

export interface InitMessage {
  type: "init";
  sessionId: string;
}

export interface TextDeltaMessage {
  type: "text_delta";
  text: string;
  sessionId?: string;
}

export interface ToolUseMessage {
  type: "tool_use";
  callId: string;
  name: string;
  input: Record<string, unknown>;
  sessionId?: string;
}

export interface ResultMessage {
  type: "result";
  text: string;
  sessionId: string;
  costUsd?: number;
  inputTokens?: number;
  outputTokens?: number;
  cacheReadTokens?: number;
  cacheWriteTokens?: number;
}

export interface ToolActivityMessage {
  type: "tool_activity";
  name: string;
  status: "started" | "completed";
  toolUseId?: string;
  input?: Record<string, unknown>;
  sessionId?: string;
}

export interface ToolResultDisplayMessage {
  type: "tool_result_display";
  toolUseId: string;
  name: string;
  output: string;
  sessionId?: string;
}

export interface ThinkingDeltaMessage {
  type: "thinking_delta";
  text: string;
  sessionId?: string;
}

/** Signals a boundary between text content blocks (new paragraph/section) */
export interface TextBlockBoundaryMessage {
  type: "text_block_boundary";
  sessionId?: string;
}

export interface ErrorMessage {
  type: "error";
  message: string;
  sessionId?: string;
}

/** Sent when ACP requires user authentication (OAuth) */
export interface AuthRequiredMessage {
  type: "auth_required";
  methods: AuthMethod[];
  authUrl?: string;
}

export interface AuthMethod {
  id: string;
  type: "agent_auth" | "env_var" | "terminal";
  displayName?: string;
  args?: string[];
  env?: Record<string, string>;
}

/** Sent after successful authentication */
export interface AuthSuccessMessage {
  type: "auth_success";
}

/** Sent when OAuth flow times out or fails */
export interface AuthTimeoutMessage {
  type: "auth_timeout";
  reason: string;
}

/** Sent when OAuth token exchange is rejected (e.g. 403 forbidden) */
export interface AuthFailedMessage {
  type: "auth_failed";
  reason: string;
  httpStatus?: number;
}

/** Sent when built-in credit balance is exhausted */
export interface CreditExhaustedMessage {
  type: "credit_exhausted";
  message: string;
  sessionId?: string;
}

/** Agent status changed (e.g. compacting context) */
export interface StatusChangeMessage {
  type: "status_change";
  status: string | null;  // "compacting" | null
  sessionId?: string;
}

/** Compact boundary — context was compacted */
export interface CompactBoundaryMessage {
  type: "compact_boundary";
  trigger: string;   // "auto" | "manual"
  preTokens: number; // token count before compaction
  sessionId?: string;
}

/** Sub-task/agent started */
export interface TaskStartedMessage {
  type: "task_started";
  taskId: string;
  description: string;
  sessionId?: string;
}

/** Sub-task/agent completed, failed, or stopped */
export interface TaskNotificationMessage {
  type: "task_notification";
  taskId: string;
  status: string;  // "completed" | "failed" | "stopped"
  summary: string;
  sessionId?: string;
}

/** Tool execution progress (elapsed time) */
export interface ToolProgressMessage {
  type: "tool_progress";
  toolUseId: string;
  toolName: string;
  elapsedTimeSeconds: number;
  sessionId?: string;
}

/** Collapsed summary of multiple tool calls */
export interface ToolUseSummaryMessage {
  type: "tool_use_summary";
  summary: string;
  precedingToolUseIds: string[];
  sessionId?: string;
}

/** Rate limit info from Claude API (forwarded from SDK rate_limit_event) */
export interface RateLimitMessage {
  type: "rate_limit";
  status: "allowed" | "allowed_warning" | "rejected" | "unknown";
  resetsAt: number | null;           // Unix timestamp (seconds)
  rateLimitType: string | null;      // "five_hour" | "seven_day" | etc.
  utilization: number | null;        // 0-1 float
  overageStatus: string | null;      // "allowed" | "rejected"
  overageDisabledReason: string | null;
  isUsingOverage: boolean;
  surpassedThreshold: number | null; // 0-1 float
  sessionId?: string;
}

/** API retry info from SDK (carries HTTP status code + typed error category) */
export interface ApiRetryMessage {
  type: "api_retry";
  httpStatus: number | null;   // Actual HTTP status (402, 429, 500, etc.) or null for connection errors
  errorType: string;           // "billing_error" | "rate_limit" | "authentication_failed" | "server_error" | "invalid_request" | "unknown"
  attempt: number;
  maxRetries: number;
  retryDelayMs: number;
  sessionId?: string;
}

/** Chat observer session completed a batch — Swift should poll observer_activity for new cards */
export interface ChatObserverPollMessage {
  type: "observer_poll";
}

/** Available models reported by the ACP SDK after session creation */
export interface ModelsAvailableMessage {
  type: "models_available";
  models: Array<{ modelId: string; name: string; description?: string }>;
}

/** Active MCP servers reported after session creation/resume */
export interface McpServersAvailableMessage {
  type: "mcp_servers_available";
  servers: Array<{ name: string; command: string; builtin: boolean }>;
}

/**
 * The bridge attempted `session/resume` but the upstream session was gone, so
 * a new session was created in its place. Emitted before the prompt result so
 * the UI can render an inline notice. `contextRestored` reports whether the
 * client supplied `priorContext` that the bridge replayed into the new session.
 */
export interface SessionExpiredMessage {
  type: "session_expired";
  reason: string;
  oldSessionId: string;
  newSessionId: string;
  contextRestored: boolean;
  restoredMessageCount: number;
  sessionId?: string;
  sessionKey?: string;
}

/**
 * Emitted immediately after `session/new` or `session/resume` succeeds, BEFORE
 * the prompt is sent to the SDK. Lets the Swift client persist the resumable
 * sessionId early, so that any error path (rate limit, credit exhausted,
 * network failure, mid-stream throw) still leaves a banked sessionId in
 * UserDefaults. Without this, the only place sessionId was saved was the
 * success path (`result` event), so any error mid-stream lost the
 * conversation: the next prompt would call `session/new` again with no
 * `resume` and the agent would have no memory of prior turns.
 */
export interface SessionStartedMessage {
  type: "session_started";
  sessionId?: string;
  sessionKey?: string;
  /** True when the bridge resumed an existing session, false when it created a new one. */
  isResume: boolean;
}

/** Result of `codex_init_probe` — reports whether codex-acp is reachable and authenticated. */
export interface CodexProbeResultMessage {
  type: "codex_probe_result";
  ok: boolean;
  /** Adapter version when reachable, e.g. "codex-acp@0.12.0". */
  agent?: string;
  authMethods?: string[];
  /** Default/current model id reported by the adapter, e.g. "gpt-5.4/high". */
  currentModelId?: string;
  /** Auth modes detected on disk (~/.codex/auth.json `auth_mode`). */
  authMode?: "chatgpt" | "api_key" | "none";
  error?: string;
}

export type OutboundMessage =
  | InitMessage
  | TextDeltaMessage
  | ToolUseMessage
  | ToolActivityMessage
  | ToolResultDisplayMessage
  | ThinkingDeltaMessage
  | TextBlockBoundaryMessage
  | ResultMessage
  | ErrorMessage
  | AuthRequiredMessage
  | AuthSuccessMessage
  | AuthTimeoutMessage
  | AuthFailedMessage
  | CreditExhaustedMessage
  | StatusChangeMessage
  | CompactBoundaryMessage
  | TaskStartedMessage
  | TaskNotificationMessage
  | ToolProgressMessage
  | ToolUseSummaryMessage
  | RateLimitMessage
  | ApiRetryMessage
  | ChatObserverPollMessage
  | ModelsAvailableMessage
  | McpServersAvailableMessage
  | SessionExpiredMessage
  | SessionStartedMessage
  | CodexProbeResultMessage;
