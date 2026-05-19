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

/**
 * Swift tells the bridge to fully tear down a specific session: send `session/close`
 * upstream so the SDK kills its claude subprocess, then drop the entry from the
 * `sessions` Map so a future warmup spawns a fresh one. Used when a pop-out window
 * closes so its detached session doesn't leak (the prior behaviour where the bridge
 * kept warm sessions forever was the structural cause of the CPU pile-up reported
 * 2026-05-14).
 */
export interface CloseSessionMessage {
  type: "close_session";
  sessionKey: string;
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

/** Start the Codex (ChatGPT) OAuth login flow. */
export interface CodexLoginMessage {
  type: "codex_login";
}

/** Cancel an in-progress Codex OAuth login flow. */
export interface CodexLoginCancelMessage {
  type: "codex_login_cancel";
}

/** Disconnect Codex by deleting `~/.codex/auth.json` and re-probing. */
export interface CodexLogoutMessage {
  type: "codex_logout";
}

export interface CancelAuthMessage {
  type: "cancel_auth";
}

/**
 * Fork the current ACP session. Creates a new session branched from the
 * end-of-conversation state of `fromSessionKey`. The upstream SDK
 * (`unstable_forkSession`) does not support mid-history anchors, so the
 * branch always starts after the last turn of the source session.
 *
 * Bridge replies with a `session_forked` outbound message carrying the new
 * sessionId so Swift can pivot the UI to the new conversation while keeping
 * the original session intact (and resumable).
 */
export interface ForkSessionMessage {
  type: "forkSession";
  fromSessionKey: string;
  toSessionKey: string;
  cwd?: string;
  /** Optional model override for the forked session. Defaults to the source session's model. */
  model?: string;
}

// Note: ACP has no separate `session/run_command` RPC. Slash commands
// surfaced via `available_commands_update` execute by sending the literal
// slash text (e.g. `/compact`) as the prompt of a normal `session/prompt`
// call. Swift therefore routes slash-command submissions through the
// existing `QueryMessage` path — no dedicated bridge handler needed.

export type InboundMessage =
  | QueryMessage
  | ToolResultMessage
  | StopMessage
  | InterruptMessage
  | CloseSessionMessage
  | AuthenticateMessage
  | WarmupMessage
  | ResetSessionMessage
  | TransferSessionMessage
  | CancelAuthMessage
  | ForkSessionMessage
  | CodexInitProbeMessage
  | CodexLoginMessage
  | CodexLoginCancelMessage
  | CodexLogoutMessage;

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
  // True when the query was cut short by a user-initiated interrupt
  // (Stop button or interrupt+send). `text` is the streamed-so-far
  // partial response, not a completed answer. Swift stamps a visible
  // "(interrupted)" marker so it doesn't look like a phantom reply
  // to whatever the user sends next.
  interrupted?: boolean;
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

/** Sent when Anthropic returns HTTP 529 `overloaded_error`. The user's account
 *  is fine — Anthropic's servers are momentarily overwhelmed. Swift should
 *  surface a retryable transient error and NOT auto-switch modes or restart
 *  the bridge. Distinct from `credit_exhausted` because the SDK reports both
 *  as errorType="rate_limit" but only one is the user's problem. */
export interface UpstreamOverloadedMessage {
  type: "upstream_overloaded";
  message: string;
  sessionId?: string;
}

/** Sent in built-in (bundled API key) mode when the key fails authentication.
 *  Indicates the backend may have rotated or revoked the key. Swift should
 *  refetch from /v1/keys, restart the bridge with the new key, and silently
 *  retry the failed query — NOT push the user into the personal-OAuth flow. */
export interface BuiltinKeyInvalidMessage {
  type: "builtin_key_invalid";
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

/**
 * Bridge auto-fell-back off a model variant the user's Claude account lacks the
 * entitlement for (e.g. `[1m]` 1M-context requires the paid usage add-on at
 * claude.ai/settings/usage). Swift uses this to sticky-hide those variants from
 * the model picker so the user can't pick a 1M model again.
 */
export interface ModelEntitlementMissingMessage {
  type: "model_entitlement_missing";
  model: string;
  downgradedTo: string;
  reason: "1m_context";
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
 * Emitted by the tool-timeout watchdog when a tool call exceeds its limit and
 * the bridge auto-cancels the in-flight ACP session. Surfaces the cancel as a
 * structured event the UI can render as a card so the user understands that
 * the turn was halted and why, instead of just seeing the error from
 * `tool_result_display` and a silent stop. Reason is verbose; toolName is
 * the un-prefixed display name; durationSeconds is the timeout that fired.
 */
export interface ToolHangCanceledMessage {
  type: "tool_hang_canceled";
  toolName: string;
  toolUseId: string;
  durationSeconds: number;
  reason: string;
  sessionId?: string;
  sessionKey?: string;
}

/**
 * Emitted by the subagent-liveness watchdog when a `Task` subagent appears to
 * have died silently — its `.output` file is 0 bytes and has not been touched
 * for `TASK_STALE_THRESHOLD_MS`. The bridge has already aborted the in-flight
 * query, sent `session/cancel`, and unregistered the session; this message
 * exists so the UI can render a "subagent stalled, turn canceled" card.
 *
 * Why this is its own event (not `tool_hang_canceled`): the trigger is
 * different (no per-tool timer; the watchdog runs on the SDK's
 * `task_started`/`task_notification` pair) and the UX needs to explain
 * subagents specifically, not generic tools.
 */
export interface TaskHangCanceledMessage {
  type: "task_hang_canceled";
  taskId: string;
  description: string;
  durationSeconds: number;
  reason: string;
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
  /** Full available models list — used by Swift to render the picker. */
  availableModels?: Array<{ modelId: string; name: string; description?: string }>;
  /** Auth modes detected on disk (~/.codex/auth.json `auth_mode`). */
  authMode?: "chatgpt" | "api_key" | "none";
  error?: string;
}

/** OAuth URL for the Codex (ChatGPT) login flow — open this in the browser. */
export interface CodexLoginUrlMessage {
  type: "codex_login_url";
  url: string;
}

/** Codex OAuth login completed and auth.json has been written. */
export interface CodexLoginCompleteMessage {
  type: "codex_login_complete";
}

/** Codex OAuth login failed. */
export interface CodexLoginErrorMessage {
  type: "codex_login_error";
  error: string;
}

/**
 * Emitted by the bridge once `preWarmSession` resolves (success or failure).
 * Pairs with `bridge_warmup_started` (fired from Swift right before
 * `ensureBridgeStarted`) so the client can compute the cold-start window:
 * - `durationMs`: time from receiving the `warmup` message to `preWarmSession`
 *   resolving (excludes Swift→bridge IPC; pair with Swift wall-clock for total).
 * - `sessionKeys`: which session keys were targeted.
 * - `ok`: false when the warmup threw — user is stuck without a usable agent
 *   until the next retry.
 */
export interface WarmupCompleteMessage {
  type: "warmup_complete";
  durationMs: number;
  sessionKeys: string[];
  ok: boolean;
  error?: string;
  /** Coarse bucket for a failed warmup: timeout | auth | mcp_spawn | session_new | unknown. */
  failureStage?: string;
  /** Session keys that did not warm up (hung past the timeout or threw). */
  failedSessions?: string[];
  /** Tail of the claude-agent-acp subprocess stderr — diagnostic context for a failed warmup. */
  stderrTail?: string;
}

/**
 * A single slash command advertised by the agent via
 * `available_commands_update`. Mirrors ACP's `AvailableCommand` schema.
 */
export interface AvailableCommandInfo {
  name: string;              // e.g. "compact"
  description: string;
  /** Free-form input hint, e.g. "[focus]" or "<query>". Omitted when the command takes no args. */
  inputHint?: string;
}

/**
 * Updated list of slash commands the agent currently accepts. Emitted by the
 * agent on session start and whenever the available command set changes
 * (e.g. after MCP server hot-reload). The Swift input field renders this as
 * a popover when the user types a leading `/`.
 */
export interface AvailableCommandsUpdateMessage {
  type: "available_commands_update";
  commands: AvailableCommandInfo[];
  sessionId?: string;
}

/**
 * Emitted after a successful `session/fork` upstream call. Swift uses this
 * to pivot the UI: bank the new sessionId as the active conversation,
 * preserve the source sessionId as resumable, and present the forked thread
 * as a fresh chat that already has the parent's context.
 */
export interface SessionForkedMessage {
  type: "session_forked";
  fromSessionId: string;
  toSessionId: string;
  fromSessionKey: string;
  toSessionKey: string;
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
  | UpstreamOverloadedMessage
  | BuiltinKeyInvalidMessage
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
  | ModelEntitlementMissingMessage
  | McpServersAvailableMessage
  | SessionExpiredMessage
  | ToolHangCanceledMessage
  | TaskHangCanceledMessage
  | SessionStartedMessage
  | CodexProbeResultMessage
  | CodexLoginUrlMessage
  | CodexLoginCompleteMessage
  | CodexLoginErrorMessage
  | WarmupCompleteMessage
  | AvailableCommandsUpdateMessage
  | SessionForkedMessage;
