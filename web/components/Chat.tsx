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
  const [showTextInput, setShowTextInput] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  // Voice input — press-and-hold to talk, show transcript in text field
  const handleVoiceTranscript = useCallback(
    (transcript: string) => {
      if (transcript.trim()) {
        setInput((prev) => (prev ? `${prev} ${transcript}` : transcript));
        setShowTextInput(true);
      }
    },
    []
  );
  const { recording, transcribing, startRecording, stopRecording } = useVoiceInput(handleVoiceTranscript);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages]);

  // Auto-resize textarea — fixed min height, expand as needed
  useEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = "40px";
    el.style.overflow = "hidden";
    if (el.scrollHeight > 40) {
      el.style.height = `${el.scrollHeight}px`;
      el.style.overflow = "auto";
    }
  }, [input]);

  // Focus input after response completes (desktop only)
  useEffect(() => {
    if (!isSending && isDesktopOnline && window.matchMedia("(min-width: 768px)").matches) {
      inputRef.current?.focus();
    }
  }, [isSending, isDesktopOnline]);

  // Auto-focus on mount — desktop only to avoid mobile keyboard
  useEffect(() => {
    if (window.matchMedia("(min-width: 768px)").matches) {
      inputRef.current?.focus();
    }
  }, []);

  // Cmd+K to focus input
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "k" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        inputRef.current?.focus();
        inputRef.current?.select();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  const handleSubmit = (e?: React.FormEvent) => {
    e?.preventDefault();
    const trimmed = input.trim();
    if (!trimmed || isSending || !isDesktopOnline) return;
    onSend(trimmed);
    setInput("");
    setShowTextInput(false);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      handleSubmit();
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
                {msg.text.trim()}
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
        ) : showTextInput ? (
          /* Text input mode — shown after voice transcript or manual switch */
          <div className="space-y-2">
            <form onSubmit={handleSubmit} className="flex gap-2 items-end">
              <textarea
                ref={inputRef}
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyDown={handleKeyDown}
                placeholder="Message..."
                className="flex-1 bg-neutral-900 text-white rounded-2xl px-4 py-[10px] text-sm resize-none leading-5 outline-none border border-neutral-700 focus:border-neutral-600 placeholder:text-neutral-500 hide-scrollbar"
                style={{ height: "40px", maxHeight: "calc(8 * 1.25rem + 1.25rem)", overflow: "hidden" }}
                disabled={isSending}
                autoFocus
              />
              <button
                type="submit"
                disabled={!input.trim() || isSending}
                className="bg-white text-black font-medium px-4 h-10 rounded-full hover:bg-neutral-200 disabled:opacity-30 disabled:cursor-not-allowed transition-colors text-sm shrink-0"
              >
                {isSending ? "..." : "Send"}
              </button>
            </form>
            <button
              type="button"
              onClick={() => setShowTextInput(false)}
              className="w-full text-xs text-neutral-500 hover:text-neutral-300 transition-colors py-1"
            >
              Switch to voice
            </button>
          </div>
        ) : (
          /* Voice mode (default) — hold to talk */
          <div className="space-y-2">
            <button
              type="button"
              onPointerDown={(e) => {
                e.preventDefault();
                if (!isSending && !transcribing) startRecording();
              }}
              onPointerUp={() => stopRecording()}
              onPointerLeave={() => stopRecording()}
              onContextMenu={(e) => e.preventDefault()}
              disabled={isSending || transcribing}
              className={`w-full flex items-center justify-center gap-3 h-12 rounded-2xl transition-colors text-sm font-medium select-none touch-none ${
                recording
                  ? "bg-red-500 text-white animate-pulse"
                  : transcribing
                    ? "bg-neutral-700 text-white/50 cursor-wait"
                    : "bg-white text-black hover:bg-neutral-200 active:bg-neutral-300"
              }`}
              aria-label={recording ? "Release to stop" : "Hold to talk"}
            >
              {transcribing ? (
                <>
                  <svg className="w-4 h-4 animate-spin" viewBox="0 0 24 24" fill="none">
                    <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeDasharray="31.4 31.4" />
                  </svg>
                  Transcribing...
                </>
              ) : (
                <>
                  <svg className="w-5 h-5" viewBox="0 0 24 24" fill="currentColor">
                    {recording ? (
                      <rect x="6" y="6" width="12" height="12" rx="2" />
                    ) : (
                      <path d="M12 1a4 4 0 0 0-4 4v7a4 4 0 0 0 8 0V5a4 4 0 0 0-4-4zm-1 18.93A7.01 7.01 0 0 1 5 13h2a5 5 0 0 0 10 0h2a7.01 7.01 0 0 1-6 6.93V22h3v2H8v-2h3v-2.07z" />
                    )}
                  </svg>
                  {recording ? "Release to stop" : "Hold to talk"}
                </>
              )}
            </button>
            <button
              type="button"
              onClick={() => setShowTextInput(true)}
              className="w-full text-xs text-neutral-500 hover:text-neutral-300 transition-colors py-1"
            >
              Type instead
            </button>
          </div>
        )}
      </div>
    </div>
  );
}
