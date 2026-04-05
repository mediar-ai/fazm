#!/usr/bin/env node
/**
 * Custom ACP entry point that patches ClaudeAcpAgent to support:
 * - Real token usage and USD cost from SDKResultSuccess (via query.next interception)
 * - Forward dropped SDK events (compaction, status, tasks, tool progress) as session updates
 *
 * Used instead of the default @agentclientprotocol/claude-agent-acp entry point.
 */

// Redirect console to stderr (same as original)
console.log = console.error;
console.info = console.error;
console.warn = console.error;
console.debug = console.error;

import { ClaudeAcpAgent, runAcp } from "@agentclientprotocol/claude-agent-acp/dist/acp-agent.js";

// Patch createSession (called by newSession, resumeSession, loadSession, forkSession)
// to wrap query.next() for cost/usage capture and SDK event forwarding.
const originalCreateSession = ClaudeAcpAgent.prototype.createSession;
ClaudeAcpAgent.prototype.createSession = async function (params, creationOpts) {
  const result = await originalCreateSession.call(this, params, creationOpts);

  // Determine the session ID the same way the SDK does
  const sid = creationOpts?.forkSession
    ? result.sessionId
    : creationOpts?.resume
      ? creationOpts.resume
      : result.sessionId;

  const session = this.sessions?.[sid];
  const acpClient = this.client;

  console.error(`[patched-acp] createSession completed: sid=${sid}, resume=${!!creationOpts?.resume}, hasQuery=${!!session?.query}`);

  if (session?.query && !session._queryPatched) {
    session._queryPatched = true;
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

      // --- Forward rate_limit_event (dropped by ACP agent) ---
      if (item.value?.type === "rate_limit_event") {
        try {
          const info = item.value.rate_limit_info ?? {};
          await acpClient.sessionUpdate({
            sessionId: sid,
            update: {
              sessionUpdate: "rate_limit",
              status: info.status ?? "unknown",
              resetsAt: info.resetsAt ?? null,
              rateLimitType: info.rateLimitType ?? null,
              utilization: info.utilization ?? null,
              overageStatus: info.overageStatus ?? null,
              overageDisabledReason: info.overageDisabledReason ?? null,
              isUsingOverage: info.isUsingOverage ?? false,
              surpassedThreshold: info.surpassedThreshold ?? null,
            },
          });
        } catch (e) {
          console.error(`[patched-acp] Forward rate_limit_event: ${e}`);
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
const originalPrompt = ClaudeAcpAgent.prototype.prompt;
ClaudeAcpAgent.prototype.prompt = async function (params) {
  const result = await originalPrompt.call(this, params);

  const session = this.sessions?.[params.sessionId];
  if (session?._lastCostUsd !== undefined) {
    const u = session._lastUsage ?? {};
    const inputTokens = u.input_tokens ?? 0;
    const outputTokens = u.output_tokens ?? 0;
    const cacheRead = u.cache_read_input_tokens ?? 0;
    const cacheWrite = u.cache_creation_input_tokens ?? 0;
    const costUsd = session._lastCostUsd;
    const totalTokens = inputTokens + cacheWrite + cacheRead + outputTokens;

    const modelUsage = session._lastModelUsage ?? {};
    const modelKeys = Object.keys(modelUsage);
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

  console.error(`[patched-acp] No usage data captured for session ${params.sessionId}`);
  return result;
};

// Run the (now patched) ACP agent
runAcp();

// Keep process alive
process.stdin.resume();
