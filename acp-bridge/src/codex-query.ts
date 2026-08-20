/**
 * Phase 2.4: query handler for codex-acp.
 *
 * Routed from index.ts when msg.model matches a Codex model id (gpt-*,
 * codex-*, o-*). Lazily spawns the CodexProvider singleton, manages a
 * sessionKey-keyed pool, streams text/tool deltas to Swift using the same
 * outbound message shapes the Claude path emits.
 *
 * Phase 2.4 added (vs 2.3):
 *   - System prompt: passed into session/new via _meta.systemPrompt AND
 *     prepended as a system-style text block on the first prompt of each
 *     session, so behavior is consistent regardless of whether codex-acp
 *     honors the meta field today.
 *   - MCP servers: real buildMcpServers() result is forwarded to session/new
 *     so codex sessions get the same fazm_tools / playwright / macos-use /
 *     whatsapp / google-workspace surface the Claude sessions get.
 *   - Resume: msg.resume → session/load (ACP standard); on failure or
 *     unsupported, falls back to session/new + priorContext replay.
 *   - Interrupt: index.ts can now call interruptCodexSession(key) which
 *     sends ACP session/cancel and unregisters the codex session.
 *   - sessionStarted notification: emitted right after session/new or
 *     session/load so the Swift client banks the resumable id even if the
 *     prompt later errors.
 *
 * Token tracking: best-effort extraction from the standard ACP
 * `promptResult.usage` field (PromptResponse.usage, `@experimental` in the
 * ACP spec) and from gemini-cli's `_meta.quota.token_count` fallback. If
 * codex-acp doesn't populate either today, the bridge reports 0; MediarWeb
 * still receives the row so the gap is visible in the dashboard.
 *
 * Still NOT yet handled (deferred to Phase 2.5):
 *   - Image / file attachments (msg.attachments is silently ignored).
 *   - Stuck-session / poisoned-session recovery (Claude has elaborate
 *     priorContext-replay logic; codex gets a single retry on resume
 *     failure and that's it).
 */

import type { QueryMessage, OutboundMessage, PriorContextEntry } from "./protocol.js";
import type { CodexProvider } from "./codex-provider.js";
import { translateCodexUpdate, type TranslatorState } from "./acp-translate.js";

export interface CodexQueryDeps {
  logErr: (msg: string) => void;
  send: (msg: OutboundMessage) => void;
  sendWithSession: (sessionId: string | undefined, msg: OutboundMessage) => void;
  getProvider: () => CodexProvider;
  buildMcpServers: (
    mode: "ask" | "act",
    cwd: string,
    sessionKey: string,
    activeModel?: string,
  ) => Array<Record<string, unknown>>;
  /** Register sessionId → sessionKey in the bridge's main routing map so
   *  streaming text deltas tag outbound messages with the right sessionKey.
   *  Without this, sendWithSession() emits sessionKey=nil and Swift drops
   *  the deltas — exactly the "first response works, follow-up freezes"
   *  symptom we hit on 2026-05-13. */
  registerSession: (sessionKey: string, entry: { sessionId: string; cwd: string; model?: string; provider: "claude" | "codex" | "gemini" }) => void;
}

/** Per-sessionKey codex session pool, kept here so it doesn't leak into index.ts globals. */
interface CodexSessionEntry {
  sessionId: string;
  cwd: string;
  modelId: string;
  systemPromptDelivered: boolean;
}
const codexSessions = new Map<string, CodexSessionEntry>();
/** Reverse map for interrupt handling — find the sessionKey owning an arbitrary sessionId. */
const codexSessionIdToKey = new Map<string, string>();

const CODEX_MODEL_PATTERN = /^(gpt-|codex-|o[0-9]-?)/i;

export function isCodexModel(modelId: string | undefined): boolean {
  if (!modelId) return false;
  return CODEX_MODEL_PATTERN.test(modelId);
}

/** Build a system-style preamble block from an optional systemPrompt + priorContext. */
function buildPreamble(
  systemPrompt: string | undefined,
  priorContext: PriorContextEntry[] | undefined,
): string | null {
  const parts: string[] = [];
  const sp = systemPrompt?.trim();
  if (sp) {
    parts.push(`<system_instructions>\n${sp}\n</system_instructions>`);
  }
  if (priorContext && priorContext.length > 0) {
    const transcript = priorContext
      .map((entry) => `[${entry.role}]: ${entry.text}`)
      .join("\n\n");
    parts.push(
      `<conversation_history>\nThe following turns happened previously in this conversation. Use them as context but do not repeat their content.\n\n${transcript}\n</conversation_history>`,
    );
  }
  return parts.length > 0 ? parts.join("\n\n") : null;
}

/** Top-level entrypoint. Mirrors handleQuery's contract: never rejects, sends `error` on failure. */
export async function handleCodexQuery(msg: QueryMessage, deps: CodexQueryDeps): Promise<void> {
  const { logErr, send, sendWithSession, getProvider, buildMcpServers, registerSession } = deps;
  const sessionKey = msg.sessionKey ?? msg.model ?? "codex-default";
  const cwd = msg.cwd ?? process.env.HOME ?? process.cwd();
  const modelId = msg.model ?? "gpt-5.4/high";
  const mode = (msg.mode ?? "act") as "ask" | "act";

  let provider: CodexProvider;
  try {
    provider = getProvider();
    provider.start();
    await provider.initialize();
  } catch (err) {
    logErr(`[codex-query] init failed: ${err}`);
    send({ type: "error", message: `Codex unavailable: ${err instanceof Error ? err.message : String(err)}` });
    return;
  }

  // Pass the model id so sibling MCP servers (Assrt) see the active provider
  // for this session instead of the bridge-spawn default. Codex/ChatGPT OAuth
  // doesn't authenticate Assrt's chat backends today; Assrt's keychain layer
  // logs a warning and falls back to Claude OAuth when ASSRT_PROVIDER=codex.
  const mcpServers = buildMcpServers(mode, cwd, sessionKey, modelId);

  // Reuse cached session for the same sessionKey + cwd + model, otherwise drop it.
  let entry = codexSessions.get(sessionKey);
  if (entry && (entry.cwd !== cwd || entry.modelId !== modelId)) {
    logErr(`[codex-query] dropping cached session for ${sessionKey}: cwd or model changed`);
    dropCodexSession(sessionKey, provider);
    entry = undefined;
  }

  let isNewSession = false;
  let resumeAttemptedSessionId: string | undefined;
  if (!entry) {
    // 1) Try session/load if Swift sent msg.resume — keeps conversation context across restarts.
    if (msg.resume) {
      try {
        await provider.request("session/load", {
          sessionId: msg.resume,
          cwd,
          mcpServers,
        });
        entry = { sessionId: msg.resume, cwd, modelId, systemPromptDelivered: true };
        codexSessions.set(sessionKey, entry);
        codexSessionIdToKey.set(entry.sessionId, sessionKey);
        registerSession(sessionKey, { sessionId: entry.sessionId, cwd, model: modelId, provider: "codex" });
        try {
          await provider.request("session/set_model", { sessionId: entry.sessionId, modelId });
        } catch (modelErr) {
          logErr(`[codex-query] session/set_model after resume failed (continuing): ${modelErr}`);
        }
        sendWithSession(entry.sessionId, { type: "session_started", sessionKey, isResume: true } as OutboundMessage);
        logErr(`[codex-query] resumed session ${entry.sessionId.slice(0, 8)} for key=${sessionKey}`);
      } catch (resumeErr) {
        logErr(`[codex-query] session/load failed (will create new with priorContext replay): ${resumeErr}`);
        resumeAttemptedSessionId = msg.resume;
        // Fall through to session/new below.
      }
    }

    // 2) Create a fresh session if no resume or resume failed.
    if (!entry) {
      try {
        const result = (await provider.request("session/new", {
          cwd,
          mcpServers,
          // Pass system prompt via _meta in case codex-acp learns to honor it.
          // We also prepend it as text on the first prompt below for guaranteed delivery.
          ...(msg.systemPrompt ? { _meta: { systemPrompt: msg.systemPrompt } } : {}),
        })) as { sessionId: string; models?: { currentModelId?: string } };
        entry = { sessionId: result.sessionId, cwd, modelId, systemPromptDelivered: false };
        codexSessions.set(sessionKey, entry);
        codexSessionIdToKey.set(entry.sessionId, sessionKey);
        registerSession(sessionKey, { sessionId: entry.sessionId, cwd, model: modelId, provider: "codex" });
        isNewSession = true;
        sendWithSession(entry.sessionId, { type: "session_started", sessionKey, isResume: false } as OutboundMessage);
        if (resumeAttemptedSessionId) {
          // Notify Swift that resume failed so the UI can show the standard
          // "session expired" inline notice (same shape Claude path emits).
          sendWithSession(entry.sessionId, {
            type: "session_expired",
            reason: "codex session/load failed; created fresh session",
            oldSessionId: resumeAttemptedSessionId,
            newSessionId: entry.sessionId,
            contextRestored: !!(msg.priorContext && msg.priorContext.length > 0),
            restoredMessageCount: msg.priorContext?.length ?? 0,
            sessionKey,
          } as OutboundMessage);
        }
        try {
          await provider.request("session/set_model", { sessionId: entry.sessionId, modelId });
        } catch (modelErr) {
          logErr(`[codex-query] session/set_model failed (continuing with default): ${modelErr}`);
        }
      } catch (err) {
        logErr(`[codex-query] session/new failed: ${err}`);
        send({ type: "error", message: `Codex session failed: ${err instanceof Error ? err.message : String(err)}` });
        return;
      }
    }
  }

  const sessionId = entry.sessionId;
  const translator: TranslatorState = {
    sessionId,
    collectedText: "",
    pendingBoundary: false,
    sendWithSession,
  };

  provider.registerSessionHandler(sessionId, (method, params) => {
    if (method !== "session/update") return;
    translateCodexUpdate(params as Record<string, unknown>, translator);
  });

  // Build the prompt blocks. On the first prompt of a fresh session, prepend a
  // system preamble (system prompt + priorContext) so the agent has context
  // even if codex-acp doesn't honor _meta.systemPrompt or session resume failed.
  const promptBlocks: Array<Record<string, unknown>> = [];
  if (!entry.systemPromptDelivered) {
    const preamble = buildPreamble(
      msg.systemPrompt,
      // Only include priorContext if we just lost the resume — don't replay
      // history on every fresh-but-intended-new session (e.g. user clicked New Chat).
      resumeAttemptedSessionId ? msg.priorContext : undefined,
    );
    if (preamble) {
      promptBlocks.push({ type: "text", text: preamble });
    }
    entry.systemPromptDelivered = true;
  }
  promptBlocks.push({ type: "text", text: msg.prompt });

  try {
    const promptResult = (await provider.request("session/prompt", {
      sessionId,
      prompt: promptBlocks,
    })) as {
      stopReason: string;
      usage?: {
        inputTokens?: number;
        outputTokens?: number;
        cachedReadTokens?: number | null;
        cachedWriteTokens?: number | null;
        totalTokens?: number;
      } | null;
      _meta?: {
        quota?: {
          token_count?: { input_tokens?: number; output_tokens?: number };
        };
      };
    };

    // Read standard ACP PromptResponse.usage first; fall back to the
    // gemini-cli-style `_meta.quota.token_count` in case codex-acp ever
    // switches to that shape. Returns 0 when codex-acp surfaces nothing
    // (current behavior at codex-acp@0.12.0) so the row still records.
    const quotaTokens = promptResult._meta?.quota?.token_count;
    const inputTokens = promptResult.usage?.inputTokens ?? quotaTokens?.input_tokens ?? 0;
    const outputTokens = promptResult.usage?.outputTokens ?? quotaTokens?.output_tokens ?? 0;
    const cacheReadTokens = promptResult.usage?.cachedReadTokens ?? 0;
    const cacheWriteTokens = promptResult.usage?.cachedWriteTokens ?? 0;

    sendWithSession(sessionId, {
      type: "result",
      text: translator.collectedText,
      sessionId,
      model: modelId,
      costUsd: 0,
      inputTokens,
      outputTokens,
      cacheReadTokens,
      cacheWriteTokens,
    });
    if (isNewSession) {
      logErr(`[codex-query] new session ${sessionId.slice(0, 8)} stop=${promptResult.stopReason} chars=${translator.collectedText.length} input=${inputTokens} output=${outputTokens}`);
    }
  } catch (err) {
    const rawMsg = err instanceof Error ? err.message : String(err);
    // codex-acp replies to a failed session/prompt with a generic JSON-RPC
    // "Internal error". The actionable reason (usage limit, auth, etc.) only
    // lands on its stderr — give it a beat to flush, then surface it instead.
    await new Promise((r) => setTimeout(r, 150));
    const turnErr = provider.getRecentTurnError();
    logErr(`[codex-query] session/prompt failed: ${rawMsg}${turnErr ? ` | turnError: ${turnErr}` : ""}`);
    send({ type: "error", message: turnErr ?? `Codex prompt failed: ${rawMsg}` });
  } finally {
    // Don't unregister the handler — reuse for follow-up prompts on the same sessionKey.
    // Cleanup happens on resetSession, interrupt, or process shutdown.
  }
}

/** Drop a cached codex session — used when Swift sends resetSession. */
export function dropCodexSession(sessionKey: string, provider: CodexProvider): void {
  const entry = codexSessions.get(sessionKey);
  if (!entry) return;
  provider.unregisterSessionHandler(entry.sessionId);
  codexSessions.delete(sessionKey);
  codexSessionIdToKey.delete(entry.sessionId);
}

/** Cancel an in-flight codex prompt for a given sessionKey. Safe no-op if no session. */
export function interruptCodexSession(sessionKey: string, provider: CodexProvider): boolean {
  const entry = codexSessions.get(sessionKey);
  if (!entry) return false;
  try {
    provider.notify("session/cancel", { sessionId: entry.sessionId });
  } catch {
    /* provider already gone */
  }
  // Drop the entry so the next prompt starts a fresh codex session — same
  // safety policy the Claude path uses after an interrupt (cancelled mid-tool
  // sessions can replay deferred chunks on the next prompt).
  dropCodexSession(sessionKey, provider);
  return true;
}

/** Cancel ALL in-flight codex sessions. Used by the legacy "interrupt all" path. */
export function interruptAllCodexSessions(provider: CodexProvider): number {
  const keys = Array.from(codexSessions.keys());
  for (const key of keys) interruptCodexSession(key, provider);
  return keys.length;
}

/** Reverse lookup: sessionKey for a live codex sessionId (approval-gate event routing). */
export function codexSessionKeyForId(sessionId: string): string | undefined {
  return codexSessionIdToKey.get(sessionId);
}

/** Forward lookup: live codex sessionId for a sessionKey (approval-gate interrupt flush). */
export function codexSessionIdForKey(sessionKey: string): string | undefined {
  return codexSessions.get(sessionKey)?.sessionId;
}

/** Diagnostic — number of live codex sessions. Used by index.ts logging. */
export function codexSessionCount(): number {
  return codexSessions.size;
}

/**
 * Wipe the cached codex session pool without touching the provider. Call this
 * right before tearing down `codexProvider` (logout / post-OAuth restart) so
 * the next prompt doesn't reuse a sessionId that died with the old subprocess
 * and trip "Resource not found" on session/prompt.
 */
export function clearCodexSessions(): void {
  codexSessions.clear();
  codexSessionIdToKey.clear();
}
