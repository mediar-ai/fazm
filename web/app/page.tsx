"use client";

export const dynamic = "force-dynamic";

import { useAuth } from "@/lib/useAuth";
import { useDesktopRelay } from "@/lib/useDesktopRelay";
import Chat from "@/components/Chat";
import ChatControls from "@/components/ChatControls";

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
    setTargetSessionKey,
    startNewChat,
    startNewPopOutChat,
    setModel,
    setWorkspace,
  } = useDesktopRelay(token);

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

  return (
    <div className="h-dvh flex flex-col">
      {/* Header */}
      <header className="safe-pt flex items-center justify-between px-4 py-3 border-b border-neutral-800">
        <div className="flex items-center gap-2">
          <h1 className="text-base font-semibold text-white">Fazm</h1>
          <span
            className={`w-2 h-2 rounded-full transition-colors ${
              isDesktopOnline ? "bg-green-400" : "bg-neutral-600"
            }`}
          />
        </div>
        <button
          onClick={signOut}
          className="text-xs text-neutral-500 hover:text-neutral-300 transition-colors"
        >
          Sign out
        </button>
      </header>

      {/* Controls — new chat / pop-out / model / workspace / target */}
      {isDesktopOnline && (
        <ChatControls
          desktopState={desktopState}
          popouts={popouts}
          targetSessionKey={targetSessionKey}
          onTargetChange={setTargetSessionKey}
          onNewChat={startNewChat}
          onNewPopOut={startNewPopOutChat}
          onSetModel={setModel}
          onSetWorkspace={setWorkspace}
        />
      )}

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
    </div>
  );
}
