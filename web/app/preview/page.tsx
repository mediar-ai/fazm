"use client";

// THROWAWAY preview route for visual verification of the chat header + controls.
// Renders the real components with mock data so the dropdowns, header spacing,
// sign-out styling, and voice-default input can be checked without a live relay.
// Delete after verifying.

import { useState } from "react";
import Chat from "@/components/Chat";
import ChatControls from "@/components/ChatControls";
import { type DesktopState, type ChatMessage } from "@/lib/useDesktopRelay";

const MOCK_STATE: DesktopState = {
  model: "claude-sonnet-4-6",
  modelLabel: "Smart",
  workspace: "/Users/matthewdi/fazm",
  voiceEnabled: true,
  availableModels: [
    { id: "gemini-flash-latest", label: "Gemini Flash", shortLabel: "Flash" },
    { id: "claude-sonnet-4-6", label: "Claude Sonnet", shortLabel: "Smart" },
    { id: "claude-opus-4-8", label: "Claude Opus", shortLabel: "Genius" },
  ],
};

const MOCK_MESSAGES: ChatMessage[] = [
  { id: "1", text: "what did i work on yesterday", sender: "user" },
  { id: "2", text: "You shipped the web chat header fixes.", sender: "ai" },
];

export default function Preview() {
  const [msgs] = useState<ChatMessage[]>(MOCK_MESSAGES);
  return (
    <div className="h-dvh flex flex-col">
      <header
        className="flex items-center gap-2 px-4 border-b border-neutral-800"
        style={{
          paddingTop: "calc(env(safe-area-inset-top) + 1rem)",
          paddingBottom: "0.875rem",
        }}
      >
        <div className="flex items-center gap-2 shrink-0">
          <button className="text-neutral-300 p-1 -ml-1" aria-label="Open chats">
            <svg className="w-5 h-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
              <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h16" />
            </svg>
          </button>
          <h1 className="text-base font-semibold text-white">Fazm</h1>
          <span className="w-2 h-2 rounded-full bg-green-400" />
        </div>
        <div className="flex-1 min-w-0 flex items-center">
          <ChatControls desktopState={MOCK_STATE} onSetModel={() => {}} onSetWorkspace={() => {}} />
        </div>
        <div className="flex items-center gap-2 shrink-0">
          <button
            type="button"
            className="flex items-center gap-1.5 text-xs text-neutral-200 bg-white/[0.06] hover:bg-white/[0.10] border border-white/[0.08] rounded-full px-3 py-1.5 transition-colors"
          >
            <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" aria-hidden>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 5v14m-7-7h14" />
            </svg>
            <span className="hidden sm:inline">New chat</span>
          </button>
          <button
            type="button"
            className="flex items-center gap-1.5 text-xs text-neutral-200 bg-white/[0.06] hover:bg-white/[0.10] border border-white/[0.08] rounded-full px-3 py-1.5 transition-colors"
          >
            Sign out
          </button>
        </div>
      </header>
      <Chat
        messages={msgs}
        onSend={() => {}}
        onStop={() => {}}
        isSending={false}
        isDesktopOnline={true}
        isConnected={true}
      />
    </div>
  );
}
