"use client";

import { useState, useRef, useEffect, useCallback } from "react";
import { type ChatMessage } from "@/lib/useDesktopRelay";
import { useVoiceInput } from "@/hooks/useVoiceInput";

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

  // Voice input — push-to-talk
  const handleVoiceTranscript = useCallback(
    (transcript: string) => {
      setInput((prev) => (prev ? `${prev} ${transcript}` : transcript));
      // Only focus input on desktop — avoid keyboard popup on mobile
      if (window.matchMedia("(min-width: 768px)").matches) {
        inputRef.current?.focus();
      }
    },
    []
  );
  const { recording, transcribing, toggleRecording } = useVoiceInput(handleVoiceTranscript);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // Auto-resize textarea
  useEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  }, [input]);

  // Focus input after response completes (desktop only)
  useEffect(() => {
    if (!isSending && isDesktopOnline && window.matchMedia("(min-width: 768px)").matches) {
      inputRef.current?.focus();
    }
  }, [isSending, isDesktopOnline]);

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

  // Empty + disconnected: center the status in the screen
  if (messages.length === 0 && !isDesktopOnline) {
    return (
      <div className="flex flex-col items-center justify-center h-full gap-3 px-6">
        <div className={`w-3 h-3 rounded-full animate-pulse ${isConnected ? "bg-red-500" : "bg-yellow-500"}`} />
        <span className="text-sm text-neutral-400 text-center">
          {isConnected
            ? "Desktop offline — open Fazm on your computer"
            : "Connecting to desktop..."}
        </span>
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full">
      {/* Messages */}
      <div className="flex-1 overflow-y-auto hide-scrollbar px-4 py-4 space-y-3">
        {messages.length === 0 && isDesktopOnline && (
          <div className="text-center text-neutral-500 mt-20 text-sm">
            Send a message to your desktop AI
          </div>
        )}

        {messages.map((msg) => (
          <div
            key={msg.id}
            className={`flex ${msg.sender === "user" ? "justify-end" : "justify-start"}`}
          >
            <div
              className={`max-w-[85%] rounded-2xl px-4 py-2.5 text-sm leading-relaxed ${
                msg.sender === "user"
                  ? "bg-white text-black rounded-br-md"
                  : "bg-neutral-800 text-white rounded-bl-md"
              }`}
            >
              {/* Tool activities */}
              {msg.toolActivities && msg.toolActivities.length > 0 && (
                <div className="mb-2 space-y-1">
                  {msg.toolActivities.map((tool, i) => (
                    <div
                      key={i}
                      className="text-xs text-neutral-400 flex items-center gap-1.5"
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
                {msg.isStreaming && (
                  <span className="inline-flex gap-1 ml-1">
                    <span className="animate-bounce" style={{ animationDelay: "0ms" }}>.</span>
                    <span className="animate-bounce" style={{ animationDelay: "150ms" }}>.</span>
                    <span className="animate-bounce" style={{ animationDelay: "300ms" }}>.</span>
                  </span>
                )}
              </div>
            </div>
          </div>
        ))}

        {/* Loading indicator */}
        {isSending && !messages.some((m) => m.isStreaming) && (
          <div className="flex justify-start">
            <div className="bg-neutral-800 text-white/80 rounded-2xl rounded-bl-md px-4 py-2.5 text-sm">
              <span className="inline-flex gap-1">
                <span className="animate-bounce" style={{ animationDelay: "0ms" }}>.</span>
                <span className="animate-bounce" style={{ animationDelay: "150ms" }}>.</span>
                <span className="animate-bounce" style={{ animationDelay: "300ms" }}>.</span>
              </span>
            </div>
          </div>
        )}

        <div ref={messagesEndRef} />
      </div>

      {/* Input */}
      <div className="px-4 py-3 border-t border-neutral-800">
        {!isDesktopOnline ? (
          <div className="flex items-center justify-center gap-2 bg-neutral-900 rounded-2xl px-4 py-3 border border-neutral-700">
            <div className={`w-2 h-2 rounded-full animate-pulse ${isConnected ? "bg-red-500" : messages.length > 0 ? "bg-red-500" : "bg-yellow-500"}`} />
            <span className="text-sm text-neutral-400">
              {isConnected
                ? "Desktop offline — open Fazm on your computer"
                : messages.length > 0
                  ? "Connection lost — reconnecting..."
                  : "Connecting to desktop..."}
            </span>
          </div>
        ) : (
          <form onSubmit={handleSubmit} className="flex gap-2 items-end">
            <textarea
              ref={inputRef}
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Message..."
              rows={1}
              className="flex-1 bg-neutral-900 text-white rounded-2xl px-4 py-2.5 text-sm resize-none leading-5 outline-none border border-neutral-700 focus:border-neutral-600 placeholder:text-neutral-500 hide-scrollbar"
              style={{ maxHeight: "calc(8 * 1.25rem + 1.25rem)", overflowY: "auto" }}
            />
            <button
              type="button"
              onClick={toggleRecording}
              disabled={isSending || transcribing}
              className={`flex items-center justify-center w-10 h-10 rounded-full transition-colors shrink-0 ${
                recording
                  ? "bg-red-500 text-white animate-pulse"
                  : transcribing
                    ? "bg-neutral-700 text-white/50 cursor-wait"
                    : "bg-neutral-800 text-white hover:bg-neutral-700 border border-neutral-700"
              }`}
              aria-label={recording ? "Stop recording" : "Start voice input"}
            >
              {transcribing ? (
                <svg className="w-4 h-4 animate-spin" viewBox="0 0 24 24" fill="none">
                  <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeDasharray="31.4 31.4" />
                </svg>
              ) : (
                <svg className="w-4 h-4" viewBox="0 0 24 24" fill="currentColor">
                  {recording ? (
                    <rect x="6" y="6" width="12" height="12" rx="2" />
                  ) : (
                    <path d="M12 1a4 4 0 0 0-4 4v7a4 4 0 0 0 8 0V5a4 4 0 0 0-4-4zm-1 18.93A7.01 7.01 0 0 1 5 13h2a5 5 0 0 0 10 0h2a7.01 7.01 0 0 1-6 6.93V22h3v2H8v-2h3v-2.07z" />
                  )}
                </svg>
              )}
            </button>
            <button
              type="submit"
              disabled={!input.trim() || isSending}
              className="bg-white text-black font-medium px-4 py-2.5 rounded-full hover:bg-neutral-200 disabled:opacity-30 disabled:cursor-not-allowed transition-colors text-sm shrink-0"
            >
              {isSending ? "..." : "Send"}
            </button>
          </form>
        )}
      </div>
    </div>
  );
}
