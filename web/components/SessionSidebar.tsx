"use client";

import { useEffect } from "react";
import type { DesktopState, PopOut } from "@/lib/useDesktopRelay";

interface Props {
  open: boolean;
  onClose: () => void;
  desktopState: DesktopState | null;
  popouts: PopOut[];
  targetSessionKey: string;
  onSelect: (key: string) => void;
  onNewChat: () => void;
  onNewPopOut: () => void;
}

const CloseIcon = () => (
  <svg className="w-5 h-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
    <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
  </svg>
);

const PlusIcon = () => (
  <svg className="w-4 h-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" aria-hidden>
    <path strokeLinecap="round" strokeLinejoin="round" d="M12 5v14m-7-7h14" />
  </svg>
);

const FloatingBarIcon = () => (
  <svg className="w-4 h-4 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
    <rect x="3" y="9" width="18" height="6" rx="3" />
  </svg>
);

const PopOutIcon = () => (
  <svg className="w-4 h-4 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
    <path strokeLinecap="round" strokeLinejoin="round" d="M14 3h7v7m0-7l-9 9M5 5h6V3H3v18h18v-8h-2v6H5V5z" />
  </svg>
);

/* Trim a workspace path to the last 2 segments so it fits on a phone screen. */
function shortWorkspace(path: string): string {
  if (!path) return "";
  const parts = path.split("/").filter(Boolean);
  if (parts.length <= 2) return "/" + parts.join("/");
  return "…/" + parts.slice(-2).join("/");
}

export default function SessionSidebar({
  open,
  onClose,
  desktopState,
  popouts,
  targetSessionKey,
  onSelect,
  onNewChat,
  onNewPopOut,
}: Props) {
  // Close on Escape
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  // Lock body scroll while open
  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = prev;
    };
  }, [open]);

  const mainItem = {
    sessionKey: "main",
    title: "Floating bar",
    subtitle: desktopState
      ? `${desktopState.modelLabel || "Model"}${
          desktopState.workspace ? " · " + shortWorkspace(desktopState.workspace) : ""
        }`
      : "Default session",
    icon: <FloatingBarIcon />,
  };

  const popoutItems = popouts.map((p) => ({
    sessionKey: p.sessionKey,
    title: p.title || "Pop-out",
    subtitle: p.isAILoading
      ? "Streaming…"
      : `${shortWorkspace(p.workspace)}${p.selectedModel ? " · " + p.selectedModel : ""}`,
    icon: <PopOutIcon />,
  }));

  return (
    <>
      {/* Backdrop */}
      <div
        className={`fixed inset-0 z-30 bg-black/60 transition-opacity ${
          open ? "opacity-100 pointer-events-auto" : "opacity-0 pointer-events-none"
        }`}
        onClick={onClose}
        aria-hidden
      />

      {/* Drawer */}
      <aside
        className={`fixed inset-y-0 left-0 z-40 w-[85%] max-w-[340px] bg-neutral-950 border-r border-neutral-800 flex flex-col transition-transform duration-200 ease-out ${
          open ? "translate-x-0" : "-translate-x-full"
        }`}
        aria-hidden={!open}
      >
        {/* Drawer header */}
        <div className="safe-pt flex items-center justify-between px-4 py-3 border-b border-neutral-800">
          <h2 className="text-sm font-semibold text-white">Chats</h2>
          <button
            type="button"
            onClick={onClose}
            className="text-neutral-400 hover:text-white transition-colors p-1 -mr-1"
            aria-label="Close sidebar"
          >
            <CloseIcon />
          </button>
        </div>

        {/* New chat / new pop-out */}
        <div className="px-3 py-3 flex gap-2 border-b border-neutral-800">
          <button
            type="button"
            onClick={() => {
              onNewChat();
              onClose();
            }}
            className="flex-1 flex items-center justify-center gap-1.5 text-xs font-medium text-neutral-100 bg-white/[0.08] hover:bg-white/[0.12] border border-white/[0.08] rounded-lg px-3 py-2 transition-colors"
          >
            <PlusIcon />
            New chat
          </button>
          <button
            type="button"
            onClick={() => {
              onNewPopOut();
              onClose();
            }}
            className="flex-1 flex items-center justify-center gap-1.5 text-xs font-medium text-neutral-200 bg-neutral-800 hover:bg-neutral-700 border border-white/[0.06] rounded-lg px-3 py-2 transition-colors"
            title="Open a new pop-out window on your Mac and start chatting with it from here"
          >
            <PopOutIcon />
            New pop-out
          </button>
        </div>

        {/* Session list */}
        <div className="flex-1 overflow-y-auto py-2 hide-scrollbar">
          {[mainItem, ...popoutItems].map((item) => {
            const active = item.sessionKey === targetSessionKey;
            return (
              <button
                key={item.sessionKey}
                type="button"
                onClick={() => {
                  onSelect(item.sessionKey);
                  onClose();
                }}
                className={`w-full flex items-start gap-3 px-4 py-3 text-left transition-colors ${
                  active
                    ? "bg-white/[0.08] text-white"
                    : "text-neutral-300 hover:bg-white/[0.04]"
                }`}
              >
                <span className={`mt-0.5 ${active ? "text-white" : "text-neutral-500"}`}>
                  {item.icon}
                </span>
                <span className="flex-1 min-w-0">
                  <span className="block text-[13px] font-medium truncate">
                    {item.title}
                  </span>
                  {item.subtitle && (
                    <span className="block text-[11px] text-neutral-500 truncate mt-0.5">
                      {item.subtitle}
                    </span>
                  )}
                </span>
                {active && (
                  <span className="mt-1.5 w-1.5 h-1.5 rounded-full bg-green-400 shrink-0" />
                )}
              </button>
            );
          })}

          {popoutItems.length === 0 && (
            <p className="px-4 py-3 text-[11px] text-neutral-600 leading-relaxed">
              No pop-outs open. Tap <span className="text-neutral-400">New pop-out</span> to spin up a detached chat window on your Mac.
            </p>
          )}
        </div>
      </aside>
    </>
  );
}
