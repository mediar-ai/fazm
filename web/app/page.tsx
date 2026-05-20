"use client";

export const dynamic = "force-dynamic";

import { useState } from "react";
import { useAuth } from "@/lib/useAuth";
import { useDesktopRelay } from "@/lib/useDesktopRelay";
import Chat from "@/components/Chat";
import ChatControls from "@/components/ChatControls";
import SessionSidebar from "@/components/SessionSidebar";

export default function Home() {
  const { user, loading, token, signIn, signOut } = useAuth();
  const {
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
    startNewChat,
    startNewPopOutChat,
    setModel,
    setWorkspace,
  } = useDesktopRelay(token);

  const [sidebarOpen, setSidebarOpen] = useState(false);

  if (loading) {
    return (
      <div className="h-dvh flex items-center justify-center">
        <div className="w-6 h-6 border-2 border-[var(--muted)] border-t-[var(--fg)] rounded-full animate-spin" />
      </div>
    );
  }

  if (!user) {
    return (
      <div className="h-dvh flex flex-col items-center justify-center gap-6 px-6 safe-pt safe-pb">
        <div className="text-center">
          <h1 className="text-2xl font-semibold mb-2">Fazm</h1>
          <p className="text-[var(--muted)] text-sm">
            Chat with your desktop AI from your phone
          </p>
        </div>
        <button
          onClick={signIn}
          className="bg-white text-black rounded-xl px-5 py-3 text-[15px] font-medium hover:bg-gray-100 active:bg-gray-200 transition-colors flex items-center gap-3"
        >
          <svg className="w-5 h-5" viewBox="0 0 24 24" aria-hidden>
            <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/>
            <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.99.66-2.26 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84A10.99 10.99 0 0 0 12 23z"/>
            <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18A10.97 10.97 0 0 0 1 12c0 1.77.42 3.45 1.18 4.93l3.66-2.84z"/>
            <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1A10.99 10.99 0 0 0 2.18 7.07l3.66 2.84C6.71 7.31 9.14 5.38 12 5.38z"/>
          </svg>
          Sign in with Google
        </button>
      </div>
    );
  }

  // Label shown next to the Fazm wordmark so users know which session they're chatting with
  const activeLabel =
    targetSessionKey === "main"
      ? "Floating bar"
      : popouts.find((p) => p.sessionKey === targetSessionKey)?.title || "Pop-out";

  return (
    <div className="h-dvh flex flex-col">
      {/* Header: hamburger | Fazm + dot | model + workspace chips | New chat + Sign out
          Everything lives on a single row per user spec; the middle cluster scrolls
          horizontally on narrow screens so it never bumps the right-side controls. */}
      <header className="safe-pt flex items-center gap-2 px-4 py-3 border-b border-neutral-800">
        {/* Left cluster: hamburger + wordmark + online dot */}
        <div className="flex items-center gap-2 shrink-0">
          <button
            type="button"
            onClick={() => setSidebarOpen(true)}
            className="text-neutral-300 hover:text-white transition-colors p-1 -ml-1 relative"
            aria-label="Open chats"
            title={isDesktopOnline ? activeLabel : "Open chats"}
          >
            <svg className="w-5 h-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
              <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h16" />
            </svg>
            {popouts.length > 0 && (
              <span className="absolute -top-0.5 -right-0.5 min-w-[14px] h-[14px] px-1 rounded-full bg-white/90 text-black text-[9px] font-bold leading-[14px] text-center">
                {popouts.length + 1}
              </span>
            )}
          </button>
          <h1 className="text-base font-semibold text-white">Fazm</h1>
          <span
            className={`w-2 h-2 rounded-full transition-colors ${
              isDesktopOnline ? "bg-green-400" : "bg-neutral-600"
            }`}
          />
        </div>

        {/* Middle cluster: compact model + workspace dropdowns. Scrolls horizontally
            if the screen is narrow so we never push the right cluster off-screen. */}
        <div className="flex-1 min-w-0 flex items-center">
          {isDesktopOnline && (
            <ChatControls
              desktopState={desktopState}
              onSetModel={setModel}
              onSetWorkspace={setWorkspace}
            />
          )}
        </div>

        {/* Right cluster: new chat + sign out */}
        <div className="flex items-center gap-2 shrink-0">
          {isDesktopOnline && (
            <button
              type="button"
              onClick={startNewChat}
              className="flex items-center gap-1.5 text-xs text-neutral-200 bg-white/[0.06] hover:bg-white/[0.10] border border-white/[0.08] rounded-full px-3 py-1.5 transition-colors"
              title="Start a new chat on the floating bar"
              aria-label="New chat"
            >
              <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" aria-hidden>
                <path strokeLinecap="round" strokeLinejoin="round" d="M12 5v14m-7-7h14" />
              </svg>
              <span className="hidden sm:inline">New chat</span>
            </button>
          )}
          <button
            onClick={signOut}
            className="text-xs text-neutral-500 hover:text-neutral-300 transition-colors"
          >
            Sign out
          </button>
        </div>
      </header>

      {/* Chat */}
      <Chat
        messages={messages}
        onSend={sendMessage}
        onStop={stopGeneration}
        isSending={isSending}
        isDesktopOnline={isDesktopOnline}
        isConnected={isConnected}
        suggestions={suggestions}
        onClearSuggestions={clearSuggestions}
      />

      {/* Slide-out sidebar with all sessions */}
      <SessionSidebar
        open={sidebarOpen}
        onClose={() => setSidebarOpen(false)}
        desktopState={desktopState}
        popouts={popouts}
        targetSessionKey={targetSessionKey}
        onSelect={selectSession}
        onNewChat={startNewChat}
        onNewPopOut={startNewPopOutChat}
      />
    </div>
  );
}
