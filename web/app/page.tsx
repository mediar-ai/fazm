"use client";

export const dynamic = "force-dynamic";

import { useAuth } from "@/lib/useAuth";
import { useDesktopRelay } from "@/lib/useDesktopRelay";
import Chat from "@/components/Chat";

export default function Home() {
  const { user, loading, token, signIn, signOut } = useAuth();
  const { isConnected, isDesktopOnline, messages, sendMessage, isSending } =
    useDesktopRelay(token);

  if (loading) {
    return (
      <div className="h-dvh flex items-center justify-center">
        <div className="w-6 h-6 border-2 border-[var(--muted)] border-t-[var(--fg)] rounded-full animate-spin" />
      </div>
    );
  }

  if (!user) {
    return (
      <div className="h-dvh flex flex-col items-center justify-center gap-6 px-6">
        <div className="text-center">
          <h1 className="text-2xl font-semibold mb-2">Fazm</h1>
          <p className="text-[var(--muted)] text-sm">
            Chat with your desktop AI from your phone
          </p>
        </div>
        <button
          onClick={signIn}
          className="bg-white text-black rounded-xl px-6 py-3 text-[15px] font-medium hover:bg-gray-100 transition-colors"
        >
          Sign in with Google
        </button>
      </div>
    );
  }

  return (
    <div className="h-dvh flex flex-col">
      {/* Header */}
      <header className="flex items-center justify-between px-4 py-3 border-b border-neutral-800">
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

      {/* Chat */}
      <Chat
        messages={messages}
        onSend={sendMessage}
        isSending={isSending}
        isDesktopOnline={isDesktopOnline}
        isConnected={isConnected}
      />
    </div>
  );
}
