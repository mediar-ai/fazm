"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import { getFirebaseAuth } from "./firebase";
import { trackEvent } from "./posthog";

export interface ChatMessage {
  id: string;
  text: string;
  sender: "user" | "ai";
  isStreaming?: boolean;
  toolActivities?: { name: string; status: "running" | "completed" }[];
}

export interface Suggestions {
  question: string;
  options: string[];
}

export interface AvailableModel {
  id: string;
  label: string;
  shortLabel: string;
}

export interface DesktopState {
  model: string;
  modelLabel: string;
  workspace: string;
  voiceEnabled: boolean;
  availableModels: AvailableModel[];
}

export interface PopOut {
  sessionKey: string;
  title: string;
  workspace: string;
  selectedModel: string;
  isAILoading: boolean;
  chatHistoryCount: number;
}

interface RelayHook {
  isConnected: boolean;
  isDesktopOnline: boolean;
  messages: ChatMessage[];
  sendMessage: (text: string) => void;
  stopGeneration: () => void;
  isSending: boolean;
  suggestions: Suggestions | null;
  clearSuggestions: () => void;
  // New session/target controls
  desktopState: DesktopState | null;
  popouts: PopOut[];
  targetSessionKey: string;          // "main" | "detached-<uuid>"
  /** Switch which session this client is chatting with. Triggers a history
   *  fetch for that session so the message list shows the right conversation. */
  selectSession: (key: string) => void;
  setTargetSessionKey: (key: string) => void;
  startNewChat: () => void;          // resets the floating bar's main chat
  startNewPopOutChat: () => void;    // opens a brand-new detached pop-out
  setModel: (id: string) => void;
  setWorkspace: (path: string) => void;
  refreshState: () => void;
  refreshPopouts: () => void;
}

const BACKOFF_INITIAL_MS = 3000;
const BACKOFF_MAX_MS = 60000;

export function useDesktopRelay(token: string | null): RelayHook {
  const [isConnected, setIsConnected] = useState(false);
  const [isDesktopOnline, setIsDesktopOnline] = useState(false);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [isSending, setIsSending] = useState(false);
  const [suggestions, setSuggestions] = useState<Suggestions | null>(null);
  const [desktopState, setDesktopState] = useState<DesktopState | null>(null);
  const [popouts, setPopouts] = useState<PopOut[]>([]);
  const [targetSessionKey, setTargetSessionKey] = useState<string>("main");
  const wsRef = useRef<WebSocket | null>(null);
  const currentAiMessageId = useRef<string | null>(null);
  const reconnectTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const offlineTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const hasConnected = useRef(false);
  const backoffMs = useRef(BACKOFF_INITIAL_MS);
  const connectRef = useRef<() => void>(() => {});
  const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL || "";

  // Debounced offline setter — don't flicker on brief WS reconnects
  const setOffline = useCallback(() => {
    if (offlineTimer.current) clearTimeout(offlineTimer.current);
    offlineTimer.current = setTimeout(() => {
      setIsDesktopOnline(false);
      trackEvent("web_desktop_offline");
    }, hasConnected.current ? 5000 : 0);
  }, []);

  const setOnline = useCallback(() => {
    if (offlineTimer.current) clearTimeout(offlineTimer.current);
    hasConnected.current = true;
    setIsDesktopOnline(true);
    trackEvent("web_desktop_online");
  }, []);

  const handleMessage = useCallback((msg: Record<string, unknown>) => {
    switch (msg.type) {
      case "chat_history": {
        const history = (msg.messages as ChatMessage[]) || [];
        const forKey = (msg.sessionKey as string) || "main";
        // Only apply if this history matches the session the user currently
        // wants to see — avoids a late-arriving history of session A overwriting
        // the display when the user has already switched to session B.
        setTargetSessionKey((curr) => {
          if (curr === forKey || (!msg.sessionKey && curr === "main")) {
            setMessages(history);
          }
          return curr;
        });
        trackEvent("web_chat_history_loaded", {
          message_count: history.length,
          sessionKey: forKey,
        });
        break;
      }

      case "query_started": {
        const aiId = crypto.randomUUID();
        currentAiMessageId.current = aiId;
        setIsSending(true);
        // New turn — clear any stale suggestions from the previous response.
        setSuggestions(null);
        setMessages((prev) => [
          ...prev,
          { id: aiId, text: "", sender: "ai", isStreaming: true },
        ]);
        break;
      }

      case "suggestions": {
        const question = (msg.question as string) || "";
        const options = (msg.options as string[]) || [];
        if (options.length > 0) {
          setSuggestions({ question, options });
          trackEvent("web_suggestions_received", { option_count: options.length });
        }
        break;
      }

      case "text_delta": {
        const id = currentAiMessageId.current;
        if (!id) break;
        setMessages((prev) =>
          prev.map((m) =>
            m.id === id ? { ...m, text: m.text + (msg.text as string) } : m
          )
        );
        break;
      }

      case "tool_activity": {
        const id = currentAiMessageId.current;
        if (!id) break;
        setMessages((prev) =>
          prev.map((m) => {
            if (m.id !== id) return m;
            const activities = [...(m.toolActivities || [])];
            const name = msg.name as string;
            const status = msg.status as string;
            if (status === "started") {
              activities.push({ name, status: "running" });
            } else {
              const idx = activities.findIndex(
                (a) => a.name === name && a.status === "running"
              );
              if (idx >= 0) activities[idx] = { name, status: "completed" };
            }
            return { ...m, toolActivities: activities };
          })
        );
        break;
      }

      case "result": {
        const id = currentAiMessageId.current;
        if (!id) break;
        setMessages((prev) =>
          prev.map((m) =>
            m.id === id
              ? { ...m, text: (msg.text as string).trim(), isStreaming: false }
              : m
          )
        );
        trackEvent("web_message_received", { text_length: (msg.text as string)?.length || 0 });
        currentAiMessageId.current = null;
        setIsSending(false);
        break;
      }

      case "error": {
        trackEvent("web_message_error", { error: msg.error || "unknown" });
        setIsSending(false);
        currentAiMessageId.current = null;
        break;
      }

      case "desktop_state": {
        const next: DesktopState = {
          model: (msg.model as string) || "",
          modelLabel: (msg.modelLabel as string) || "",
          workspace: (msg.workspace as string) || "",
          voiceEnabled: Boolean(msg.voiceEnabled),
          availableModels: (msg.availableModels as AvailableModel[]) || [],
        };
        setDesktopState(next);
        break;
      }

      case "popouts_list": {
        const list = (msg.popouts as PopOut[]) || [];
        setPopouts(list);
        // If the user's currently-targeted pop-out closed on the desktop, fall
        // back to the floating bar so we never send into a dead session.
        setTargetSessionKey((curr) => {
          if (curr === "main") return curr;
          return list.some((p) => p.sessionKey === curr) ? curr : "main";
        });
        break;
      }
    }
  }, []);

  // Force-refresh the Firebase ID token (e.g. after a 401)
  const refreshToken = useCallback(async (): Promise<string | null> => {
    try {
      const auth = getFirebaseAuth();
      const user = auth.currentUser;
      if (!user) return null;
      const freshToken = await user.getIdToken(true);
      trackEvent("web_relay_token_refreshed");
      return freshToken;
    } catch (err) {
      trackEvent("web_relay_token_refresh_failed", { error: (err as Error).message });
      return null;
    }
  }, []);

  // Schedule a reconnect with current backoff
  const scheduleReconnect = useCallback(() => {
    reconnectTimer.current = setTimeout(() => connectRef.current(), backoffMs.current);
  }, []);

  // Open a WebSocket to the discovered tunnel URL
  const openWebSocket = useCallback((tunnelUrl: string) => {
    const wsUrl = tunnelUrl.replace(/^http/, "ws");
    const ws = new WebSocket(wsUrl);
    wsRef.current = ws;

    ws.onopen = () => {
      setIsConnected(true);
      setOnline();
      backoffMs.current = BACKOFF_INITIAL_MS;
      trackEvent("web_relay_connected");
      // Ask for history of whichever session the user last had selected (defaults
      // to "main" on a fresh load).
      ws.send(JSON.stringify({ type: "request_history", sessionKey: "main" }));
      // Ask for current desktop state (model list, voice setting, workspace, etc.)
      // so the UI can populate the model dropdown immediately on connect.
      ws.send(JSON.stringify({ type: "request_state" }));
    };

    ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      handleMessage(msg);
    };

    ws.onclose = () => {
      setIsConnected(false);
      setOffline();
      setIsSending(false);
      wsRef.current = null;
      trackEvent("web_relay_disconnected");
      scheduleReconnect();
    };

    ws.onerror = () => {
      trackEvent("web_connection_error");
      ws.close();
    };
  }, [setOnline, setOffline, handleMessage, scheduleReconnect]);

  // Discover tunnel URL and connect
  const connect = useCallback(async () => {
    if (!token || !backendUrl) return;

    try {
      const res = await fetch(`${backendUrl}/api/relay/discover`, {
        headers: { Authorization: `Bearer ${token}` },
      });

      // On 401, force-refresh the Firebase token and retry immediately
      if (res.status === 401) {
        trackEvent("web_relay_discover_failed", { status: 401, action: "refreshing_token" });
        const freshToken = await refreshToken();
        if (freshToken) {
          const retryRes = await fetch(`${backendUrl}/api/relay/discover`, {
            headers: { Authorization: `Bearer ${freshToken}` },
          });
          if (!retryRes.ok) {
            trackEvent("web_relay_discover_failed", { status: retryRes.status, after_refresh: true });
            setOffline();
            backoffMs.current = Math.min(backoffMs.current * 2, BACKOFF_MAX_MS);
            scheduleReconnect();
            return;
          }
          const { tunnel_url } = await retryRes.json();
          if (!tunnel_url) {
            trackEvent("web_relay_discover_failed", { reason: "no_tunnel_url" });
            setOffline();
            backoffMs.current = Math.min(backoffMs.current * 2, BACKOFF_MAX_MS);
            scheduleReconnect();
            return;
          }
          openWebSocket(tunnel_url);
          return;
        }
        // Token refresh failed — retry with backoff
        setOffline();
        backoffMs.current = Math.min(backoffMs.current * 2, BACKOFF_MAX_MS);
        scheduleReconnect();
        return;
      }

      if (!res.ok) {
        trackEvent("web_relay_discover_failed", { status: res.status });
        setOffline();
        backoffMs.current = Math.min(backoffMs.current * 2, BACKOFF_MAX_MS);
        scheduleReconnect();
        return;
      }

      const { tunnel_url } = await res.json();
      if (!tunnel_url) {
        trackEvent("web_relay_discover_failed", { reason: "no_tunnel_url" });
        setOffline();
        backoffMs.current = Math.min(backoffMs.current * 2, BACKOFF_MAX_MS);
        scheduleReconnect();
        return;
      }

      openWebSocket(tunnel_url);
    } catch (err) {
      trackEvent("web_connection_error", { error: (err as Error).message });
      backoffMs.current = Math.min(backoffMs.current * 2, BACKOFF_MAX_MS);
      scheduleReconnect();
    }
  }, [token, backendUrl, setOffline, refreshToken, openWebSocket, scheduleReconnect]);

  // Keep connectRef in sync so scheduleReconnect always calls the latest connect
  useEffect(() => {
    connectRef.current = connect;
  }, [connect]);

  useEffect(() => {
    connect();
    return () => {
      clearTimeout(reconnectTimer.current);
      clearTimeout(offlineTimer.current);
      wsRef.current?.close();
    };
  }, [connect]);

  const sendMessage = useCallback(
    (text: string) => {
      if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) {
        console.error(
          "[useDesktopRelay] sendMessage called but WebSocket is not open (state:",
          wsRef.current?.readyState,
          "). Triggering reconnect."
        );
        connectRef.current();
        return;
      }

      const userMsg: ChatMessage = {
        id: crypto.randomUUID(),
        text,
        sender: "user",
      };
      setMessages((prev) => [...prev, userMsg]);
      // User sent a reply — suggestion pills are now stale.
      setSuggestions(null);
      trackEvent("web_message_sent", {
        text_length: text.length,
        target: targetSessionKey,
      });

      wsRef.current.send(
        JSON.stringify({
          type: "send_message",
          text,
          sessionKey: targetSessionKey,
        })
      );
    },
    [targetSessionKey]
  );

  const clearSuggestions = useCallback(() => {
    setSuggestions(null);
  }, []);

  const stopGeneration = useCallback(() => {
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;
    wsRef.current.send(JSON.stringify({ type: "stop" }));
    trackEvent("web_stop_generation");

    // Finalize the current streaming message locally
    const id = currentAiMessageId.current;
    if (id) {
      setMessages((prev) =>
        prev.map((m) =>
          m.id === id ? { ...m, isStreaming: false } : m
        )
      );
      currentAiMessageId.current = null;
    }
    setIsSending(false);
  }, []);

  // Convenience: fire a control command through the existing distributed-
  // notification dispatch on the desktop. Anything that works from the floating
  // bar (newChat, newPopOutChat, setModel:..., setWorkspace:..., ...) works here.
  const sendControl = useCallback((command: string) => {
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;
    wsRef.current.send(JSON.stringify({ type: "control", command }));
  }, []);

  const startNewChat = useCallback(() => {
    trackEvent("web_new_chat");
    // Clear the local message list immediately so the UI feels snappy; the
    // desktop will reset its own history on the next request_history.
    setMessages([]);
    setSuggestions(null);
    sendControl("newChat");
    // If user was targeting a pop-out, drop back to the floating bar — newChat
    // only resets the main session.
    setTargetSessionKey("main");
  }, [sendControl]);

  const startNewPopOutChat = useCallback(() => {
    trackEvent("web_new_popout_chat");
    sendControl("newPopOutChat");
    // The popouts_list push will arrive shortly; auto-pick the newest one as
    // the target so the user's next message goes into the fresh pop-out.
    // Done in the handler below by diffing the list.
  }, [sendControl]);

  const setModel = useCallback(
    (id: string) => {
      trackEvent("web_set_model", { model: id });
      sendControl(`setModel:${id}`);
    },
    [sendControl]
  );

  const setWorkspace = useCallback(
    (path: string) => {
      trackEvent("web_set_workspace");
      sendControl(`setWorkspace:${path}`);
    },
    [sendControl]
  );

  const refreshState = useCallback(() => {
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;
    wsRef.current.send(JSON.stringify({ type: "request_state" }));
  }, []);

  const refreshPopouts = useCallback(() => {
    if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;
    wsRef.current.send(JSON.stringify({ type: "request_popouts" }));
  }, []);

  // Switch to a different chat session (floating bar or a specific pop-out).
  // Clears the visible message list and asks the desktop for that session's
  // history; the next "chat_history" push populates the UI.
  const selectSession = useCallback((key: string) => {
    trackEvent("web_select_session", { sessionKey: key });
    setTargetSessionKey(key);
    setMessages([]);
    setSuggestions(null);
    currentAiMessageId.current = null;
    setIsSending(false);
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(
        JSON.stringify({ type: "request_history", sessionKey: key })
      );
    }
  }, []);

  // Track previous popout list so we can auto-target a newly opened pop-out
  // after the user clicks "New pop-out".
  const prevPopoutKeys = useRef<Set<string>>(new Set());
  useEffect(() => {
    const currKeys = new Set(popouts.map((p) => p.sessionKey));
    // Find any keys present now but not before — those are new pop-outs.
    const newKeys = [...currKeys].filter((k) => !prevPopoutKeys.current.has(k));
    if (newKeys.length > 0) {
      // Always target the most recently added one.
      setTargetSessionKey(newKeys[newKeys.length - 1]);
    }
    prevPopoutKeys.current = currKeys;
  }, [popouts]);

  // After we successfully connect, immediately ask for state + pop-outs so the
  // header populates without the user having to click anything.
  useEffect(() => {
    if (!isConnected) return;
    refreshState();
    refreshPopouts();
    // Light polling for pop-outs (every 10s) so closes/opens triggered from the
    // desktop show up without a manual refresh.
    const id = setInterval(() => {
      refreshPopouts();
    }, 10_000);
    return () => clearInterval(id);
  }, [isConnected, refreshState, refreshPopouts]);

  return {
    isConnected,
    isDesktopOnline,
    messages,
    sendMessage,
    stopGeneration,
    isSending,
    suggestions,
    clearSuggestions,
    desktopState,
    popouts,
    targetSessionKey,
    selectSession,
    setTargetSessionKey,
    startNewChat,
    startNewPopOutChat,
    setModel,
    setWorkspace,
    refreshState,
    refreshPopouts,
  };
}
