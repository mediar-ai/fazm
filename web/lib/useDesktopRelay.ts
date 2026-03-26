"use client";

import { useState, useEffect, useRef, useCallback } from "react";
import { trackEvent } from "./posthog";

export interface ChatMessage {
  id: string;
  text: string;
  sender: "user" | "ai";
  isStreaming?: boolean;
  toolActivities?: { name: string; status: "running" | "completed" }[];
}

interface RelayHook {
  isConnected: boolean;
  isDesktopOnline: boolean;
  messages: ChatMessage[];
  sendMessage: (text: string) => void;
  stopGeneration: () => void;
  isSending: boolean;
}

export function useDesktopRelay(token: string | null): RelayHook {
  const [isConnected, setIsConnected] = useState(false);
  const [isDesktopOnline, setIsDesktopOnline] = useState(false);
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [isSending, setIsSending] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const currentAiMessageId = useRef<string | null>(null);
  const reconnectTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const offlineTimer = useRef<ReturnType<typeof setTimeout>>(undefined);
  const hasConnected = useRef(false);
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

  // Discover tunnel URL and connect
  const connect = useCallback(async () => {
    if (!token || !backendUrl) return;

    try {
      const res = await fetch(`${backendUrl}/api/relay/discover`, {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (!res.ok) {
        trackEvent("web_relay_discover_failed", { status: res.status });
        setOffline();
        reconnectTimer.current = setTimeout(connect, 5000);
        return;
      }

      const { tunnel_url } = await res.json();
      if (!tunnel_url) {
        trackEvent("web_relay_discover_failed", { reason: "no_tunnel_url" });
        setOffline();
        reconnectTimer.current = setTimeout(connect, 5000);
        return;
      }

      // Connect WebSocket to tunnel
      const wsUrl = tunnel_url.replace(/^http/, "ws");
      const ws = new WebSocket(wsUrl);
      wsRef.current = ws;

      ws.onopen = () => {
        setIsConnected(true);
        setOnline();
        trackEvent("web_relay_connected");
        ws.send(JSON.stringify({ type: "request_history" }));
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
        reconnectTimer.current = setTimeout(connect, 3000);
      };

      ws.onerror = () => {
        trackEvent("web_connection_error");
        ws.close();
      };
    } catch (err) {
      trackEvent("web_connection_error", { error: (err as Error).message });
      reconnectTimer.current = setTimeout(connect, 5000);
    }
  }, [token, backendUrl, setOffline, setOnline]);

  const handleMessage = useCallback((msg: Record<string, unknown>) => {
    switch (msg.type) {
      case "chat_history": {
        const history = (msg.messages as ChatMessage[]) || [];
        setMessages(history);
        trackEvent("web_chat_history_loaded", { message_count: history.length });
        break;
      }

      case "query_started": {
        const aiId = crypto.randomUUID();
        currentAiMessageId.current = aiId;
        setIsSending(true);
        setMessages((prev) => [
          ...prev,
          { id: aiId, text: "", sender: "ai", isStreaming: true },
        ]);
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
    }
  }, []);

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
      if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;

      const userMsg: ChatMessage = {
        id: crypto.randomUUID(),
        text,
        sender: "user",
      };
      setMessages((prev) => [...prev, userMsg]);
      trackEvent("web_message_sent", { text_length: text.length });

      wsRef.current.send(
        JSON.stringify({ type: "send_message", text, sessionKey: "main" })
      );
    },
    []
  );

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

  return { isConnected, isDesktopOnline, messages, sendMessage, stopGeneration, isSending };
}
