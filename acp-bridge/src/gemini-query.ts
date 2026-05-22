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
 * Not yet handled (parity gaps with Claude path):
 *   - Cost / token tracking (gemini-cli's usage_update schema not yet
 *     adapter-ized; costUsd is reported as 0 same as Codex).
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
  ) => Array<Record<string, unknown>>;
  registerSession: (sessionKey: string, entry: { sessionId: string; cwd: string; model?: string }) => void;
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

  const mcpServers = buildMcpServers(mode, cwd, sessionKey);

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
        registerSession(sessionKey, { sessionId: entry.sessionId, cwd, model: modelId });
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
        registerSession(sessionKey, { sessionId: entry.sessionId, cwd, model: modelId });
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

  try {
    const promptResult = (await provider.request("session/prompt", {
      sessionId,
      prompt: promptBlocks,
    })) as { stopReason: string };

    sendWithSession(sessionId, {
      type: "result",
      text: translator.collectedText,
      sessionId,
      costUsd: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheWriteTokens: 0,
    });
    if (isNewSession) {
      logErr(`[gemini-query] new session ${sessionId.slice(0, 8)} stop=${promptResult.stopReason} chars=${translator.collectedText.length}`);
    }
  } catch (err) {
    const rawMsg = err instanceof Error ? err.message : String(err);
    await new Promise((r) => setTimeout(r, 150));
    const turnErr = provider.getRecentTurnError();
    logErr(`[gemini-query] session/prompt failed: ${rawMsg}${turnErr ? ` | turnError: ${turnErr}` : ""}`);
    send({ type: "error", message: turnErr ?? `Gemini prompt failed: ${rawMsg}` });
  }
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
