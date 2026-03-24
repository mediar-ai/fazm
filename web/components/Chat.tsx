"use client";

import { useState, useRef, useEffect } from "react";
import { type ChatMessage } from "@/lib/useDesktopRelay";

interface ChatProps {
  messages: ChatMessage[];
  onSend: (text: string) => void;
  isSending: boolean;
  isDesktopOnline: boolean;
  isConnected: boolean;
}

export default function Chat({
  messages,
  onSend,
  isSending,
  isDesktopOnline,
  isConnected,
}: ChatProps) {
  const [input, setInput] = useState("");
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = input.trim();
    if (!trimmed || isSending || !isDesktopOnline) return;
    onSend(trimmed);
    setInput("");
    inputRef.current?.focus();
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSubmit(e);
    }
  };

  return (
    <div className="flex flex-col h-full">
      {/* Status bar */}
      {!isDesktopOnline && (
        <div className="px-4 py-2 text-center text-sm bg-yellow-900/50 text-yellow-200 border-b border-yellow-800/50">
          {isConnected
            ? "Desktop is offline — open Fazm on your computer"
            : "Connecting..."}
        </div>
      )}

      {/* Messages */}
      <div className="flex-1 overflow-y-auto hide-scrollbar px-4 py-4 space-y-4">
        {messages.length === 0 && isDesktopOnline && (
          <div className="text-center text-[var(--muted)] mt-20">
            Send a message to your desktop AI
          </div>
        )}

        {messages.map((msg) => (
          <div
            key={msg.id}
            className={`flex ${msg.sender === "user" ? "justify-end" : "justify-start"}`}
          >
            <div
              className={`max-w-[85%] rounded-2xl px-4 py-2.5 text-[15px] leading-relaxed ${
                msg.sender === "user"
                  ? "bg-[var(--accent)] text-white"
                  : "bg-[var(--border)] text-[var(--fg)]"
              }`}
            >
              {/* Tool activities */}
              {msg.toolActivities && msg.toolActivities.length > 0 && (
                <div className="mb-2 space-y-1">
                  {msg.toolActivities.map((tool, i) => (
                    <div
                      key={i}
                      className="text-xs text-[var(--muted)] flex items-center gap-1.5"
                    >
                      <span
                        className={`inline-block w-1.5 h-1.5 rounded-full ${
                          tool.status === "running"
                            ? "bg-yellow-400 animate-pulse"
                            : "bg-green-400"
                        }`}
                      />
                      {tool.name}
                    </div>
                  ))}
                </div>
              )}

              {/* Message text */}
              <div className="whitespace-pre-wrap break-words">
                {msg.text}
                {msg.isStreaming && !msg.text && (
                  <span className="inline-block w-2 h-4 bg-[var(--muted)] animate-pulse rounded-sm" />
                )}
                {msg.isStreaming && msg.text && (
                  <span className="inline-block w-1.5 h-4 bg-[var(--muted)] animate-pulse rounded-sm ml-0.5" />
                )}
              </div>
            </div>
          </div>
        ))}

        <div ref={messagesEndRef} />
      </div>

      {/* Input */}
      <form
        onSubmit={handleSubmit}
        className="border-t border-[var(--border)] p-3 flex gap-2 items-end"
      >
        <textarea
          ref={inputRef}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={
            isDesktopOnline ? "Message..." : "Desktop offline"
          }
          disabled={!isDesktopOnline}
          rows={1}
          className="flex-1 bg-[var(--border)] text-[var(--fg)] rounded-xl px-4 py-2.5 text-[15px] resize-none outline-none placeholder:text-[var(--muted)] disabled:opacity-40"
          style={{ maxHeight: "120px" }}
        />
        <button
          type="submit"
          disabled={!input.trim() || isSending || !isDesktopOnline}
          className="bg-[var(--accent)] text-white rounded-xl px-4 py-2.5 text-[15px] font-medium disabled:opacity-40 transition-opacity shrink-0"
        >
          {isSending ? "..." : "Send"}
        </button>
      </form>
    </div>
  );
}
