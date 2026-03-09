// JSON lines protocol between Swift app and Node.js ACP bridge
// Extended from agent-bridge protocol with authentication message types

// === Swift → Bridge (stdin) ===

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
  imageBase64?: string;
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

export type InboundMessage =
  | QueryMessage
  | ToolResultMessage
  | StopMessage
  | InterruptMessage
  | AuthenticateMessage
  | WarmupMessage
  | ResetSessionMessage;

// === Bridge → Swift (stdout) ===

export interface InitMessage {
  type: "init";
  sessionId: string;
}

export interface TextDeltaMessage {
  type: "text_delta";
  text: string;
}

export interface ToolUseMessage {
  type: "tool_use";
  callId: string;
  name: string;
  input: Record<string, unknown>;
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
}

export interface ToolResultDisplayMessage {
  type: "tool_result_display";
  toolUseId: string;
  name: string;
  output: string;
}

export interface ThinkingDeltaMessage {
  type: "thinking_delta";
  text: string;
}

/** Signals a boundary between text content blocks (new paragraph/section) */
export interface TextBlockBoundaryMessage {
  type: "text_block_boundary";
}

export interface ErrorMessage {
  type: "error";
  message: string;
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

/** Sent when built-in credit balance is exhausted */
export interface CreditExhaustedMessage {
  type: "credit_exhausted";
  message: string;
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
  | CreditExhaustedMessage;
