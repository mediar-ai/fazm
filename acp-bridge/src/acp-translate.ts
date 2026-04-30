/**
 * Shared ACP session/update → outbound message translator.
 *
 * Phase 2.4: extracted from codex-query.ts so any future ACP-shaped backend
 * (codex-acp today, gemini-acp / cursor-acp / etc. tomorrow) emits the same
 * Swift-facing event shape without re-implementing the agent_message_chunk /
 * tool_call / tool_call_update mapping.
 *
 * NOTE: index.ts's `handleSessionUpdate` for the Claude path is intentionally
 * NOT routed through here yet. That function does a lot of Claude-Code-
 * specific work (boundary tracking, ToolSearch hiding, in-flight tool
 * watchdogs, task tracking, compact / api_retry / rate_limit forwarding) that
 * doesn't apply to other backends. Unifying both is Phase 2.5; for now we
 * settle for "every NEW backend uses translateCodexUpdate", which kills the
 * duplication going forward without touching the working Claude path.
 */

import type { OutboundMessage } from "./protocol.js";

export interface TranslatorState {
  sessionId: string;
  /** Accumulated assistant text — provider-side state so the caller can echo it in `result`. */
  collectedText: string;
  /** Whether the next text delta should be preceded by a text_block_boundary. */
  pendingBoundary: boolean;
  sendWithSession: (sessionId: string | undefined, msg: OutboundMessage) => void;
}

/**
 * Translate one ACP `session/update` notification into one or more outbound
 * messages and emit them through `state.sendWithSession`. Mutates
 * `state.collectedText` and `state.pendingBoundary` in place.
 */
export function translateCodexUpdate(
  params: Record<string, unknown>,
  state: TranslatorState,
): void {
  const update = params.update as Record<string, unknown> | undefined;
  if (!update) return;
  const { sessionId, sendWithSession } = state;

  switch (update.sessionUpdate as string | undefined) {
    case "agent_message_chunk": {
      const content = update.content as { type?: string; text?: string } | undefined;
      const text = content?.text ?? "";
      if (!text) return;
      if (state.pendingBoundary) {
        sendWithSession(sessionId, { type: "text_block_boundary" });
        state.pendingBoundary = false;
      }
      state.collectedText += text;
      sendWithSession(sessionId, { type: "text_delta", text });
      return;
    }

    case "agent_thought_chunk": {
      const content = update.content as { type?: string; text?: string } | undefined;
      const text = content?.text ?? "";
      if (text) sendWithSession(sessionId, { type: "thinking_delta", text });
      return;
    }

    case "tool_call": {
      const toolCallId = (update.toolCallId as string) ?? "";
      const title = (update.title as string) ?? "tool";
      const rawInput = (update.rawInput as Record<string, unknown> | undefined) ?? {};
      sendWithSession(sessionId, {
        type: "tool_use",
        callId: toolCallId,
        name: title,
        input: rawInput,
      });
      sendWithSession(sessionId, {
        type: "tool_activity",
        name: title,
        status: "started",
        toolUseId: toolCallId,
        input: rawInput,
      });
      // Next assistant text after a tool call should start a new bubble.
      state.pendingBoundary = true;
      return;
    }

    case "tool_call_update": {
      const toolCallId = (update.toolCallId as string) ?? "";
      const title = (update.title as string) ?? "tool";
      const status = (update.status as string) ?? "completed";
      if (status !== "completed" && status !== "failed" && status !== "cancelled") return;

      // Best-effort: extract a textual blob from the content array.
      const contentArr = update.content as Array<Record<string, unknown>> | undefined;
      let outputText = "";
      if (Array.isArray(contentArr)) {
        for (const c of contentArr) {
          // Direct MCP {type:"text", text:"..."}
          if (c.type === "text" && typeof c.text === "string") outputText += c.text;
          // ACP-wrapped {type:"content", content:{type:"text", text:"..."}}
          const inner = c.content as { type?: string; text?: string } | undefined;
          if (inner?.type === "text" && inner.text) outputText += inner.text;
        }
      }
      if (outputText) {
        sendWithSession(sessionId, {
          type: "tool_result_display",
          toolUseId: toolCallId,
          name: title,
          output: outputText.length > 2000 ? outputText.slice(0, 2000) + "\n... (truncated)" : outputText,
        });
      }
      sendWithSession(sessionId, {
        type: "tool_activity",
        name: title,
        status: "completed",
        toolUseId: toolCallId,
      });
      return;
    }

    case "plan": {
      const entries = update.entries as Array<{ content?: string }> | undefined;
      if (!Array.isArray(entries)) return;
      for (const entry of entries) {
        if (entry?.content) {
          sendWithSession(sessionId, { type: "thinking_delta", text: entry.content + "\n" });
        }
      }
      return;
    }

    case "usage_update":
    case "available_commands_update":
    case "current_mode_update":
      // Phase 2.4: ignore. usage_update can drive cost tracking when codex-acp
      // surfaces a stable schema for it.
      return;

    default:
      // Unknown update type — silently ignore; codex-acp can introduce new
      // sessionUpdate kinds and we shouldn't crash the stream over them.
      return;
  }
}
