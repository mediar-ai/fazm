"use client";

import { useState, useRef, useEffect, useCallback } from "react";
import { type ChatMessage } from "@/lib/useDesktopRelay";
import { useVoiceInput } from "@/hooks/useVoiceInput";
import { MarkdownMessage, CopyButton } from "./MarkdownMessage";

interface ChatProps {
  messages: ChatMessage[];
  onSend: (text: string) => void;
  onStop?: () => void;
  isSending: boolean;
  isDesktopOnline: boolean;
  isConnected: boolean;
}

/* ------------------------------------------------------------------ */
/*  Typing indicator (3-dot bounce — matches desktop)                 */
/* ------------------------------------------------------------------ */

function TypingIndicator() {
  return (
    <span className="inline-flex gap-[3px] ml-0.5 align-middle">
      {[0, 150, 300].map((delay) => (
        <span
          key={delay}
          className="inline-block w-[5px] h-[5px] rounded-full bg-current opacity-60 animate-bounce"
          style={{ animationDelay: `${delay}ms` }}
        />
      ))}
    </span>
  );
}

/* ------------------------------------------------------------------ */
/*  Tool activity row — collapsible like desktop ToolCallsGroup       */
/* ------------------------------------------------------------------ */

function ToolActivities({
  tools,
}: {
  tools: { name: string; status: "running" | "completed" }[];
}) {
  const [expanded, setExpanded] = useState(false);
  const running = tools.filter((t) => t.status === "running");
  const completed = tools.filter((t) => t.status === "completed");
  const allDone = running.length === 0 && completed.length > 0;

  // Summary line
  const summary = running.length > 0
    ? running.length === 1
      ? running[0].name
      : `${running.length} actions`
    : completed.length === 1
      ? completed[0].name
      : `${completed.length} actions`;

  return (
    <div className="mb-2">
      <button
        onClick={() => setExpanded(!expanded)}
        className="flex items-center gap-1.5 text-xs text-neutral-400 hover:text-neutral-300 transition-colors w-full text-left"
      >
        {/* Chevron */}
        <svg
          className={`w-3 h-3 transition-transform duration-200 shrink-0 ${expanded ? "rotate-90" : ""}`}
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2.5"
        >
          <path strokeLinecap="round" strokeLinejoin="round" d="M9 5l7 7-7 7" />
        </svg>

        {/* Status icon */}
        {allDone ? (
          <svg className="w-3 h-3 text-green-400 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
            <path strokeLinecap="round" strokeLinejoin="round" d="M5 13l4 4L19 7" />
          </svg>
        ) : (
          <svg className="w-3 h-3 animate-spin text-neutral-400 shrink-0" viewBox="0 0 24 24" fill="none">
            <circle cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeDasharray="31.4 31.4" />
          </svg>
        )}

        <span className="truncate">{summary}</span>
      </button>

      {/* Expanded list */}
      {expanded && (
        <div className="mt-1.5 ml-3 space-y-1 border-l border-white/[0.06] pl-3">
          {tools.map((tool, i) => (
            <div key={i} className="flex items-center gap-1.5 text-xs text-neutral-500">
              <span
                className={`inline-block w-1.5 h-1.5 rounded-full shrink-0 ${
                  tool.status === "running"
                    ? "bg-yellow-400 animate-pulse"
                    : "bg-green-400"
                }`}
              />
              <span className="truncate">{tool.name}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/*  Message bubble — wraps content with hover copy button              */
/* ------------------------------------------------------------------ */

function MessageBubble({
  msg,
  isStreaming,
}: {
  msg: ChatMessage;
  isStreaming?: boolean;
}) {
  const isUser = msg.sender === "user";

  return (
    <div className={`flex ${isUser ? "justify-end" : "justify-start"}`}>
      <div className="group relative max-w-[85%]">
        <div
          className={`rounded-2xl px-4 py-2.5 text-sm leading-relaxed ${
            isUser
              ? "bg-white text-black rounded-br-md"
              : "bg-neutral-800/80 text-white rounded-bl-md border border-white/[0.04]"
          }`}
        >
          {/* Tool activities — collapsible */}
          {msg.toolActivities && msg.toolActivities.length > 0 && (
            <ToolActivities tools={msg.toolActivities} />
          )}

          {/* Message content */}
          {msg.text.trim() ? (
            <MarkdownMessage text={msg.text.trim()} sender={msg.sender} />
          ) : null}

          {/* Streaming cursor */}
          {isStreaming && <TypingIndicator />}
        </div>

        {/* Copy button — appears on hover, positioned outside the bubble */}
        {msg.text.trim() && !isStreaming && (
          <div
            className={`absolute top-1 opacity-0 group-hover:opacity-100 transition-opacity duration-150 ${
              isUser ? "-left-8" : "-right-8"
            }`}
          >
            <CopyButton text={msg.text.trim()} />
          </div>
        )}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/*  Main Chat component                                               */
/* ------------------------------------------------------------------ */

export default function Chat({
  messages,
  onSend,
  onStop,
  isSending,
  isDesktopOnline,
  isConnected,
}: ChatProps) {
  const [input, setInput] = useState("");
  const [showTextInput, setShowTextInput] = useState(false);
  const [userScrolled, setUserScrolled] = useState(false);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const scrollContainerRef = useRef<HTMLDivElement>(null);
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
  const { recording, transcribing, startRecording, stopRecording } =
    useVoiceInput(handleVoiceTranscript);

  // Auto-scroll — respects manual scroll-up
  useEffect(() => {
    if (userScrolled) return;
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, userScrolled]);

  // Detect user scroll-up
  useEffect(() => {
    const el = scrollContainerRef.current;
    if (!el) return;
    const onScroll = () => {
      const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
      setUserScrolled(!atBottom);
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => el.removeEventListener("scroll", onScroll);
  }, []);

  // Auto-resize textarea
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
    if (!trimmed || !isDesktopOnline) return;
    onSend(trimmed);
    setInput("");
    // Do NOT reset showTextInput — keep the text input visible after sending
    // so the user can type a follow-up without switching back to voice mode.
    setUserScrolled(false); // resume auto-scroll on new send
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
        <div
          className={`w-3 h-3 rounded-full animate-pulse ${
            isConnected ? "bg-red-500" : "bg-yellow-500"
          }`}
        />
        <span className="text-sm text-neutral-400 text-center">
          {isConnected
            ? "Desktop offline — open Fazm on your computer"
            : "Connecting to desktop..."}
        </span>
      </div>
    );
  }

  const isStreaming = messages.some((m) => m.isStreaming);
  const placeholder = isSending
    ? "Ask follow up... (queued)"
    : "Message...";

  return (
    <div className="flex flex-col h-full">
      {/* Messages */}
      <div
        ref={scrollContainerRef}
        className="flex-1 overflow-y-auto hide-scrollbar px-4 py-4 space-y-3"
      >
        {messages.length === 0 && isDesktopOnline && (
          <div className="text-center text-neutral-500 mt-20 text-sm">
            Send a message to your desktop AI
          </div>
        )}

        {messages.map((msg) => (
          <MessageBubble
            key={msg.id}
            msg={msg}
            isStreaming={msg.isStreaming}
          />
        ))}

        {/* Thinking indicator — shown when sending but no streaming message yet */}
        {isSending && !isStreaming && (
          <div className="flex justify-start">
            <div className="bg-neutral-800/80 text-white/80 rounded-2xl rounded-bl-md px-4 py-2.5 text-sm border border-white/[0.04]">
              <TypingIndicator />
            </div>
          </div>
        )}

        <div ref={messagesEndRef} />
      </div>

      {/* Scroll-to-bottom button */}
      {userScrolled && (
        <div className="absolute bottom-24 left-1/2 -translate-x-1/2 z-10">
          <button
            onClick={() => {
              setUserScrolled(false);
              messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
            }}
            className="bg-neutral-700/90 hover:bg-neutral-600 text-white/80 text-xs px-3 py-1.5 rounded-full backdrop-blur-sm border border-white/[0.08] transition-colors shadow-lg"
          >
            <svg className="w-3 h-3 inline mr-1" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
              <path strokeLinecap="round" strokeLinejoin="round" d="M19 14l-7 7m0 0l-7-7m7 7V3" />
            </svg>
            New messages
          </button>
        </div>
      )}

      {/* Input area */}
      <div className="px-4 py-3 border-t border-neutral-800">
        {!isDesktopOnline ? (
          <div className="flex items-center justify-center gap-2 bg-neutral-900 rounded-2xl px-4 py-3 border border-neutral-700">
            <div
              className={`w-2 h-2 rounded-full animate-pulse ${
                isConnected
                  ? "bg-red-500"
                  : messages.length > 0
                    ? "bg-red-500"
                    : "bg-yellow-500"
              }`}
            />
            <span className="text-sm text-neutral-400">
              {isConnected
                ? "Desktop offline — open Fazm on your computer"
                : messages.length > 0
                  ? "Connection lost — reconnecting..."
                  : "Connecting to desktop..."}
            </span>
          </div>
        ) : showTextInput ? (
          /* Text input mode */
          <div className="space-y-2">
            <form onSubmit={handleSubmit} className="flex gap-2 items-end">
              <textarea
                ref={inputRef}
                value={input}
                onChange={(e) => setInput(e.target.value)}
                onKeyDown={handleKeyDown}
                placeholder={placeholder}
                className="flex-1 bg-neutral-900 text-white rounded-2xl px-4 py-[10px] text-sm resize-none leading-5 outline-none border border-neutral-700 focus:border-neutral-600 placeholder:text-neutral-500 hide-scrollbar"
                style={{
                  height: "40px",
                  maxHeight: "calc(8 * 1.25rem + 1.25rem)",
                  overflow: "hidden",
                }}
                autoFocus
              />
              {/* Stop / Send button */}
              {isSending ? (
                <button
                  type="button"
                  onClick={onStop}
                  className="bg-red-500/80 hover:bg-red-500 text-white font-medium px-3 h-10 rounded-full transition-colors text-sm shrink-0 flex items-center gap-1.5"
                  title="Stop generating"
                >
                  <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="currentColor">
                    <rect x="6" y="6" width="12" height="12" rx="2" />
                  </svg>
                  Stop
                </button>
              ) : (
                <button
                  type="submit"
                  disabled={!input.trim()}
                  className="bg-white text-black font-medium px-4 h-10 rounded-full hover:bg-neutral-200 disabled:opacity-30 disabled:cursor-not-allowed transition-colors text-sm shrink-0"
                >
                  Send
                </button>
              )}
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
            {/* Stop button when streaming */}
            {isSending && onStop && (
              <button
                type="button"
                onClick={onStop}
                className="w-full flex items-center justify-center gap-2 h-10 rounded-2xl bg-red-500/10 hover:bg-red-500/20 text-red-400 text-sm font-medium transition-colors border border-red-500/20 mb-2"
              >
                <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="currentColor">
                  <rect x="6" y="6" width="12" height="12" rx="2" />
                </svg>
                Stop generating
              </button>
            )}

            <button
              type="button"
              onPointerDown={(e) => {
                e.preventDefault();
                if (!transcribing) startRecording();
              }}
              onPointerUp={() => stopRecording()}
              onPointerLeave={() => stopRecording()}
              onContextMenu={(e) => e.preventDefault()}
              disabled={transcribing}
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
                    <circle
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      strokeWidth="3"
                      strokeLinecap="round"
                      strokeDasharray="31.4 31.4"
                    />
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
