/**
 * Per-query handler for gemini-cli's --experimental-acp surface.
 *
 * Routed from index.ts when msg.model matches a Gemini model id (gemini-*,
 * auto-gemini-*). Mirrors codex-query.ts so the two backends share session
 * lifecycle, MCP wiring, resume, and outbound translation.
 *
 * Off-by-default: index.ts only constructs the GeminiProvider singleton when
 * FAZM_GEMINI_ENABLED=true. With the flag off, isGeminiModel() never matches
 * any model in availableModels (because the probe never ran), and this file
 * stays dormant.
 *
 * Token tracking: extracted from promptResult._meta.quota.token_count, where
 * gemini-cli stamps per-turn input/output totals (the standard ACP `usage`
 * field on PromptResponse is left null by gemini-cli today). costUsd stays 0
 * because gemini-cli doesn't compute dollar cost; MediarWeb derives it from
 * the model + token counts.
 *
 * Not yet handled (parity gaps with Claude path):
 *   - Image / file attachments (msg.attachments is silently ignored).
 *   - Stuck-session recovery beyond a single retry on resume failure.
 */

import type { QueryMessage, OutboundMessage, PriorContextEntry } from "./protocol.js";
import type { GeminiProvider } from "./gemini-provider.js";
import { translateCodexUpdate, type TranslatorState } from "./acp-translate.js";

export interface GeminiQueryDeps {
  logErr: (msg: string) => void;
  send: (msg: OutboundMessage) => void;
  sendWithSession: (sessionId: string | undefined, msg: OutboundMessage) => void;
  getProvider: () => GeminiProvider;
  buildMcpServers: (
    mode: "ask" | "act",
    cwd: string,
    sessionKey: string,
    activeModel?: string,
  ) => Array<Record<string, unknown>>;
  registerSession: (sessionKey: string, entry: { sessionId: string; cwd: string; model?: string; provider: "claude" | "codex" | "gemini" }) => void;
}

interface GeminiSessionEntry {
  sessionId: string;
  cwd: string;
  modelId: string;
  systemPromptDelivered: boolean;
}

const geminiSessions = new Map<string, GeminiSessionEntry>();
const geminiSessionIdToKey = new Map<string, string>();

/**
 * Matches gemini-cli model ids surfaced by `session/new`:
 *   gemini-2.5-pro, gemini-2.5-flash, gemini-3.1-pro-preview-customtools,
 *   gemini-3-flash-preview, auto-gemini-3, auto-gemini-2.5, etc.
 */
const GEMINI_MODEL_PATTERN = /^(gemini-|auto-gemini-)/i;

export function isGeminiModel(modelId: string | undefined): boolean {
  if (!modelId) return false;
  return GEMINI_MODEL_PATTERN.test(modelId);
}

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

export async function handleGeminiQuery(msg: QueryMessage, deps: GeminiQueryDeps): Promise<void> {
  const { logErr, send, sendWithSession, getProvider, buildMcpServers, registerSession } = deps;
  const sessionKey = msg.sessionKey ?? msg.model ?? "gemini-default";
  const cwd = msg.cwd ?? process.env.HOME ?? process.cwd();
  const modelId = msg.model ?? "auto-gemini-3";
  const mode = (msg.mode ?? "act") as "ask" | "act";

  let provider: GeminiProvider;
  try {
    provider = getProvider();
    provider.start();
    await provider.initialize();
    await provider.authenticate();
  } catch (err) {
    logErr(`[gemini-query] init failed: ${err}`);
    send({ type: "error", message: `Gemini unavailable: ${err instanceof Error ? err.message : String(err)}` });
    return;
  }

  // Pass the model id so sibling MCP servers (Assrt) pin their credential
  // provider to Gemini for this session instead of inheriting the bridge-spawn
  // default (which is usually Claude). See buildMcpServers' Assrt block.
  const mcpServers = buildMcpServers(mode, cwd, sessionKey, modelId);

  let entry = geminiSessions.get(sessionKey);
  if (entry && (entry.cwd !== cwd || entry.modelId !== modelId)) {
    logErr(`[gemini-query] dropping cached session for ${sessionKey}: cwd or model changed`);
    dropGeminiSession(sessionKey, provider);
    entry = undefined;
  }

  let isNewSession = false;
  let resumeAttemptedSessionId: string | undefined;
  if (!entry) {
    if (msg.resume) {
      try {
        await provider.request("session/load", {
          sessionId: msg.resume,
          cwd,
          mcpServers,
        });
        entry = { sessionId: msg.resume, cwd, modelId, systemPromptDelivered: true };
        geminiSessions.set(sessionKey, entry);
        geminiSessionIdToKey.set(entry.sessionId, sessionKey);
        registerSession(sessionKey, { sessionId: entry.sessionId, cwd, model: modelId, provider: "gemini" });
        try {
          await provider.request("session/set_model", { sessionId: entry.sessionId, modelId });
        } catch (modelErr) {
          logErr(`[gemini-query] session/set_model after resume failed (continuing): ${modelErr}`);
        }
        sendWithSession(entry.sessionId, { type: "session_started", sessionKey, isResume: true } as OutboundMessage);
        logErr(`[gemini-query] resumed session ${entry.sessionId.slice(0, 8)} for key=${sessionKey}`);
      } catch (resumeErr) {
        logErr(`[gemini-query] session/load failed (will create new with priorContext replay): ${resumeErr}`);
        resumeAttemptedSessionId = msg.resume;
      }
    }

    if (!entry) {
      try {
        const result = (await provider.request("session/new", {
          cwd,
          mcpServers,
          ...(msg.systemPrompt ? { _meta: { systemPrompt: msg.systemPrompt } } : {}),
        })) as { sessionId: string; models?: { currentModelId?: string } };
        entry = { sessionId: result.sessionId, cwd, modelId, systemPromptDelivered: false };
        geminiSessions.set(sessionKey, entry);
        geminiSessionIdToKey.set(entry.sessionId, sessionKey);
        registerSession(sessionKey, { sessionId: entry.sessionId, cwd, model: modelId, provider: "gemini" });
        isNewSession = true;
        sendWithSession(entry.sessionId, { type: "session_started", sessionKey, isResume: false } as OutboundMessage);
        if (resumeAttemptedSessionId) {
          sendWithSession(entry.sessionId, {
            type: "session_expired",
            reason: "gemini session/load failed; created fresh session",
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
          logErr(`[gemini-query] session/set_model failed (continuing with default): ${modelErr}`);
        }
      } catch (err) {
        logErr(`[gemini-query] session/new failed: ${err}`);
        send({ type: "error", message: `Gemini session failed: ${err instanceof Error ? err.message : String(err)}` });
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

  const promptBlocks: Array<Record<string, unknown>> = [];
  if (!entry.systemPromptDelivered) {
    const preamble = buildPreamble(
      msg.systemPrompt,
      resumeAttemptedSessionId ? msg.priorContext : undefined,
    );
    if (preamble) {
      promptBlocks.push({ type: "text", text: preamble });
    }
    entry.systemPromptDelivered = true;
  }
  promptBlocks.push({ type: "text", text: msg.prompt });

  // Mark this prompt in flight so the provider can rescue any session/update
  // that gemini-cli emits under a mismatched sessionId (see decideGeminiRoute).
  provider.beginActivePrompt(sessionId);
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

    // gemini-cli emits per-turn tokens at `_meta.quota.token_count` (see
    // gemini bundle: `promptTokenCount` / `candidatesTokenCount` are summed
    // across the turn's inner Gemini API calls and returned in this shape).
    // The standard ACP `usage` field is left null by gemini-cli today; fall
    // back to it in case a future version starts populating it.
    const quotaTokens = promptResult._meta?.quota?.token_count;
    const inputTokens = quotaTokens?.input_tokens ?? promptResult.usage?.inputTokens ?? 0;
    const outputTokens = quotaTokens?.output_tokens ?? promptResult.usage?.outputTokens ?? 0;
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
      logErr(`[gemini-query] new session ${sessionId.slice(0, 8)} stop=${promptResult.stopReason} chars=${translator.collectedText.length} input=${inputTokens} output=${outputTokens}`);
    }
    if (translator.collectedText.length === 0) {
      // Distinguishes a genuine empty turn from a routing drop: if the model
      // produced text that was lost to an id mismatch, a preceding "rescued
      // id-mismatched session/update" line will be present; if not, the model
      // truly produced no assistant text this turn.
      logErr(`[gemini-query] empty turn session=${sessionId.slice(0, 8)} stop=${promptResult.stopReason} (no assistant text collected)`);
    }
  } catch (err) {
    const rawMsg = err instanceof Error ? err.message : String(err);
    await new Promise((r) => setTimeout(r, 150));
    const turnErr = provider.getRecentTurnError();
    logErr(`[gemini-query] session/prompt failed: ${rawMsg}${turnErr ? ` | turnError: ${turnErr}` : ""}`);
    send({ type: "error", message: turnErr ?? `Gemini prompt failed: ${rawMsg}` });
  } finally {
    provider.endActivePrompt(sessionId);
  }
}

/**
 * Eagerly create + cache a Gemini session for `sessionKey` so the first user
 * query reuses it instead of paying session/new + MCP-server spin-up on the
 * visible turn. This is the Gemini analogue of the Claude warmup in
 * preWarmSession (index.ts): create the session, register it, pin the model,
 * and emit `session_started` so Swift banks the sessionId for resume — but it
 * never sends a prompt.
 *
 * Writes into the same module-level `geminiSessions` cache that
 * handleGeminiQuery reads (keyed by sessionKey), so the next query
 * short-circuits to this warm session as long as cwd + model still match.
 * Throws on failure so the caller (preWarmSession) can record a per-session
 * warmup outcome; a failed warm just means the session is created lazily on
 * the first query, exactly as before.
 */
export async function prewarmGeminiSession(
  cfg: { key: string; model: string; systemPrompt?: string; resume?: string },
  cwd: string,
  deps: GeminiQueryDeps,
): Promise<void> {
  const { logErr, sendWithSession, getProvider, buildMcpServers, registerSession } = deps;
  const sessionKey = cfg.key;
  const modelId = cfg.model;

  // Idempotent: already warm for this exact key + cwd + model.
  const existing = geminiSessions.get(sessionKey);
  if (existing && existing.cwd === cwd && existing.modelId === modelId) {
    logErr(`[gemini-warmup] '${sessionKey}' already warm (${existing.sessionId.slice(0, 8)})`);
    return;
  }

  const provider = getProvider();
  // start/initialize/authenticate are idempotent — handleGeminiQuery calls them
  // on every query — so this is safe even if the startup probe already ran.
  provider.start();
  await provider.initialize();
  await provider.authenticate();

  const mcpServers = buildMcpServers("act", cwd, sessionKey, modelId);

  // Resume a saved session if Swift handed us an id (main/floating). On failure
  // fall back to a fresh session quietly — warmup has no live turn to attach a
  // session_expired notice to (unlike handleGeminiQuery).
  if (cfg.resume) {
    try {
      await provider.request("session/load", { sessionId: cfg.resume, cwd, mcpServers });
      const entry: GeminiSessionEntry = { sessionId: cfg.resume, cwd, modelId, systemPromptDelivered: true };
      geminiSessions.set(sessionKey, entry);
      geminiSessionIdToKey.set(entry.sessionId, sessionKey);
      registerSession(sessionKey, { sessionId: entry.sessionId, cwd, model: modelId, provider: "gemini" });
      try {
        await provider.request("session/set_model", { sessionId: entry.sessionId, modelId });
      } catch (modelErr) {
        logErr(`[gemini-warmup] set_model after resume failed for '${sessionKey}' (continuing): ${modelErr}`);
      }
      sendWithSession(entry.sessionId, { type: "session_started", sessionKey, isResume: true } as OutboundMessage);
      logErr(`[gemini-warmup] resumed '${sessionKey}' session ${entry.sessionId.slice(0, 8)}`);
      return;
    } catch (resumeErr) {
      logErr(`[gemini-warmup] session/load failed for '${sessionKey}', creating fresh: ${resumeErr}`);
    }
  }

  // Fresh session. systemPromptDelivered=false so the first real query delivers
  // the system-prompt preamble (matches handleGeminiQuery's new-session path).
  const result = (await provider.request("session/new", {
    cwd,
    mcpServers,
    ...(cfg.systemPrompt ? { _meta: { systemPrompt: cfg.systemPrompt } } : {}),
  })) as { sessionId: string };
  const entry: GeminiSessionEntry = { sessionId: result.sessionId, cwd, modelId, systemPromptDelivered: false };
  geminiSessions.set(sessionKey, entry);
  geminiSessionIdToKey.set(entry.sessionId, sessionKey);
  registerSession(sessionKey, { sessionId: entry.sessionId, cwd, model: modelId, provider: "gemini" });
  try {
    await provider.request("session/set_model", { sessionId: entry.sessionId, modelId });
  } catch (modelErr) {
    logErr(`[gemini-warmup] set_model failed for '${sessionKey}' (continuing with default): ${modelErr}`);
  }
  sendWithSession(entry.sessionId, { type: "session_started", sessionKey, isResume: false } as OutboundMessage);
  logErr(`[gemini-warmup] pre-warmed '${sessionKey}' session ${entry.sessionId.slice(0, 8)} (model=${modelId})`);
}

export function dropGeminiSession(sessionKey: string, provider: GeminiProvider): void {
  const entry = geminiSessions.get(sessionKey);
  if (!entry) return;
  provider.unregisterSessionHandler(entry.sessionId);
  geminiSessions.delete(sessionKey);
  geminiSessionIdToKey.delete(entry.sessionId);
}

export function interruptGeminiSession(sessionKey: string, provider: GeminiProvider): boolean {
  const entry = geminiSessions.get(sessionKey);
  if (!entry) return false;
  try {
    provider.notify("session/cancel", { sessionId: entry.sessionId });
  } catch {
    /* provider already gone */
  }
  dropGeminiSession(sessionKey, provider);
  return true;
}

export function interruptAllGeminiSessions(provider: GeminiProvider): number {
  const keys = Array.from(geminiSessions.keys());
  for (const key of keys) interruptGeminiSession(key, provider);
  return keys.length;
}

export function geminiSessionCount(): number {
  return geminiSessions.size;
}

export function clearGeminiSessions(): void {
  geminiSessions.clear();
  geminiSessionIdToKey.clear();
}
