#!/usr/bin/env node
/**
 * Custom ACP entry point that patches ClaudeAcpAgent to support:
 * - Model selection via session/new params (uses setModel() after session creation)
 * - Real token usage and USD cost from SDKResultSuccess (via query.next interception)
 * - Forward dropped SDK events (compaction, status, tasks, tool progress) as session updates
 *
 * Used instead of the default @zed-industries/claude-agent-acp entry point.
 */

// Redirect console to stderr (same as original)
console.log = console.error;
console.info = console.error;
console.warn = console.error;
console.debug = console.error;

import { ClaudeAcpAgent, runAcp } from "@zed-industries/claude-agent-acp/dist/acp-agent.js";

// Patch newSession to:
// 1. Pass model via setModel() after session creation
// 2. Wrap query.next() to capture real cost/usage from SDKResultSuccess messages
// 3. Forward dropped SDK events (compaction, status, tasks, tool progress) as session updates
const originalNewSession = ClaudeAcpAgent.prototype.newSession;
ClaudeAcpAgent.prototype.newSession = async function (params) {
  const result = await originalNewSession.call(this, params);

  const session = this.sessions?.[result.sessionId];
  const acpClient = this.client;
  const sid = result.sessionId;

  if (session?.query) {
    const originalNext = session.query.next.bind(session.query);
    session.query.next = async function (...args) {
      const item = await originalNext(...args);

      // Capture cost/usage from SDKResultSuccess
      if (
        item.value?.type === "result" &&
        item.value?.subtype === "success"
      ) {
        const prevSessionCost = session._sessionCostUsd ?? 0;
        session._lastCostUsd = item.value.total_cost_usd - prevSessionCost;
        session._sessionCostUsd = item.value.total_cost_usd;
        session._lastUsage = item.value.usage;
        session._lastModelUsage = item.value.modelUsage;
      }

      // --- Forward dropped system messages ---
      if (item.value?.type === "system") {
        const subtype = item.value.subtype;
        try {
          if (subtype === "compact_boundary") {
            await acpClient.sessionUpdate({
              sessionId: sid,
              update: {
                sessionUpdate: "compact_boundary",
                trigger: item.value.compact_metadata?.trigger ?? "auto",
                preTokens: item.value.compact_metadata?.pre_tokens ?? 0,
              },
            });
          } else if (subtype === "status") {
            await acpClient.sessionUpdate({
              sessionId: sid,
              update: { sessionUpdate: "status_change", status: item.value.status },
            });
          } else if (subtype === "task_started") {
            await acpClient.sessionUpdate({
              sessionId: sid,
              update: {
                sessionUpdate: "task_started",
                taskId: item.value.task_id ?? "",
                description: item.value.description ?? "",
              },
            });
          } else if (subtype === "task_notification") {
            await acpClient.sessionUpdate({
              sessionId: sid,
              update: {
                sessionUpdate: "task_notification",
                taskId: item.value.task_id ?? "",
                status: item.value.status ?? "",
                summary: item.value.summary ?? "",
              },
            });
          }
        } catch (e) {
          console.error(`[patched-acp] Forward system/${subtype}: ${e}`);
        }
      }

      // --- Forward dropped top-level messages ---
      try {
        if (item.value?.type === "tool_progress") {
          await acpClient.sessionUpdate({
            sessionId: sid,
            update: {
              sessionUpdate: "tool_progress",
              toolUseId: item.value.tool_use_id ?? "",
              toolName: item.value.tool_name ?? "",
              elapsedTimeSeconds: item.value.elapsed_time_seconds ?? 0,
            },
          });
        }
        if (item.value?.type === "tool_use_summary") {
          await acpClient.sessionUpdate({
            sessionId: sid,
            update: {
              sessionUpdate: "tool_use_summary",
              summary: item.value.summary ?? "",
              precedingToolUseIds: item.value.preceding_tool_use_ids ?? [],
            },
          });
        }
      } catch (e) {
        console.error(`[patched-acp] Forward ${item.value?.type}: ${e}`);
      }

      // --- Forward compaction stream chunks ---
      if (item.value?.type === "stream_event") {
        const event = item.value.event;
        try {
          if (event?.type === "content_block_start" && event.content_block?.type === "compaction") {
            await acpClient.sessionUpdate({
              sessionId: sid,
              update: { sessionUpdate: "compaction_start" },
            });
          }
          if (event?.type === "content_block_delta" && event.delta?.type === "compaction_delta") {
            await acpClient.sessionUpdate({
              sessionId: sid,
              update: {
                sessionUpdate: "compaction_delta",
                text: event.delta.text ?? event.delta.compaction ?? "",
              },
            });
          }
        } catch (_) {}
      }

      return item;
    };
  }

  return result;
};

// Patch prompt() to attach captured cost/usage to the return value.
// The ACP PromptResponse supports usage (experimental) and _meta for extras.
const originalPrompt = ClaudeAcpAgent.prototype.prompt;
ClaudeAcpAgent.prototype.prompt = async function (params) {
  const result = await originalPrompt.call(this, params);

  const session = this.sessions?.[params.sessionId];
  if (session?._lastCostUsd !== undefined) {
    // usage fields are snake_case (raw Anthropic API format)
    const u = session._lastUsage ?? {};
    const inputTokens = u.input_tokens ?? 0;
    const outputTokens = u.output_tokens ?? 0;
    const cacheRead = u.cache_read_input_tokens ?? 0;
    const cacheWrite = u.cache_creation_input_tokens ?? 0;
    const costUsd = session._lastCostUsd;

    // Total = new input + cache writes + cache reads + output
    const totalTokens = inputTokens + cacheWrite + cacheRead + outputTokens;

    const modelKeys = Object.keys(session._lastModelUsage ?? {});
    console.error(
      `[patched-acp] Usage: model=${modelKeys.join(",") || "unknown"}, cost=$${costUsd}, ` +
      `input=${inputTokens}, output=${outputTokens}, ` +
      `cacheWrite=${cacheWrite}, cacheRead=${cacheRead}, ` +
      `total=${totalTokens}`
    );

    const augmented = {
      ...result,
      usage: {
        inputTokens,
        outputTokens,
        cachedReadTokens: cacheRead,
        cachedWriteTokens: cacheWrite,
        totalTokens,
      },
      _meta: { costUsd },
    };
    delete session._lastCostUsd;
    delete session._lastUsage;
    delete session._lastModelUsage;
    return augmented;
  }

  return result;
};

// Run the (now patched) ACP agent
runAcp();

// Keep process alive
process.stdin.resume();
