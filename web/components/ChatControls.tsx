"use client";

import { useEffect, useRef, useState } from "react";
import {
  type AvailableModel,
  type DesktopState,
  type PopOut,
} from "@/lib/useDesktopRelay";

interface Props {
  desktopState: DesktopState | null;
  popouts: PopOut[];
  targetSessionKey: string;
  onTargetChange: (key: string) => void;
  onNewChat: () => void;
  onNewPopOut: () => void;
  onSetModel: (id: string) => void;
  onSetWorkspace: (path: string) => void;
}

/* ------------------------------------------------------------------ */
/*  Tiny inline icons                                                 */
/* ------------------------------------------------------------------ */

const PlusIcon = () => (
  <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" aria-hidden>
    <path strokeLinecap="round" strokeLinejoin="round" d="M12 5v14m-7-7h14" />
  </svg>
);

const PopOutIcon = () => (
  <svg className="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
    <path strokeLinecap="round" strokeLinejoin="round" d="M14 3h7v7m0-7l-9 9M5 5h6V3H3v18h18v-8h-2v6H5V5z" />
  </svg>
);

const ChevronIcon = ({ open }: { open: boolean }) => (
  <svg
    className={`w-3 h-3 transition-transform duration-150 ${open ? "rotate-180" : ""}`}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2.5"
    aria-hidden
  >
    <path strokeLinecap="round" strokeLinejoin="round" d="M6 9l6 6 6-6" />
  </svg>
);

/* ------------------------------------------------------------------ */
/*  Lightweight dropdown                                              */
/* ------------------------------------------------------------------ */

function Dropdown({
  label,
  items,
  selectedId,
  onSelect,
  emptyText,
}: {
  label: string;
  items: { id: string; primary: string; secondary?: string }[];
  selectedId: string | null;
  onSelect: (id: string) => void;
  emptyText?: string;
}) {
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onClick);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onClick);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const selected = items.find((it) => it.id === selectedId);

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-1.5 text-xs text-neutral-300 bg-neutral-800/70 hover:bg-neutral-700 active:bg-neutral-600 border border-white/[0.06] rounded-full px-3 py-1.5 transition-colors"
        title={label}
      >
        <span className="truncate max-w-[140px]">{selected?.primary || emptyText || label}</span>
        <ChevronIcon open={open} />
      </button>
      {open && (
        <div className="absolute right-0 top-full mt-1 z-20 min-w-[200px] max-w-[280px] bg-neutral-900 border border-white/[0.08] rounded-xl shadow-xl py-1 max-h-[60vh] overflow-y-auto hide-scrollbar">
          {items.length === 0 ? (
            <div className="px-3 py-2 text-xs text-neutral-500">{emptyText || "Nothing here"}</div>
          ) : (
            items.map((it) => {
              const isActive = it.id === selectedId;
              return (
                <button
                  key={it.id}
                  type="button"
                  onClick={() => {
                    onSelect(it.id);
                    setOpen(false);
                  }}
                  className={`w-full text-left px-3 py-2 text-xs transition-colors flex items-start gap-2 ${
                    isActive
                      ? "bg-white/[0.06] text-white"
                      : "text-neutral-300 hover:bg-white/[0.04]"
                  }`}
                >
                  <span className={`mt-1 w-1.5 h-1.5 rounded-full shrink-0 ${isActive ? "bg-green-400" : "bg-transparent"}`} />
                  <span className="flex-1 min-w-0">
                    <span className="block truncate">{it.primary}</span>
                    {it.secondary && (
                      <span className="block text-[10px] text-neutral-500 truncate">{it.secondary}</span>
                    )}
                  </span>
                </button>
              );
            })
          )}
        </div>
      )}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/*  Main controls bar                                                 */
/* ------------------------------------------------------------------ */

export default function ChatControls({
  desktopState,
  popouts,
  targetSessionKey,
  onTargetChange,
  onNewChat,
  onNewPopOut,
  onSetModel,
  onSetWorkspace,
}: Props) {
  // Local state for workspace input (committed on blur / Enter so we don't
  // spam the desktop with a setWorkspace per keystroke).
  const [workspaceDraft, setWorkspaceDraft] = useState("");
  const [workspaceEditing, setWorkspaceEditing] = useState(false);

  // Mirror remote workspace into the input whenever it changes upstream and
  // the user isn't actively editing.
  useEffect(() => {
    if (!workspaceEditing && desktopState) {
      setWorkspaceDraft(desktopState.workspace || "");
    }
  }, [desktopState, workspaceEditing]);

  const commitWorkspace = () => {
    setWorkspaceEditing(false);
    const trimmed = workspaceDraft.trim();
    if (trimmed !== (desktopState?.workspace || "")) {
      onSetWorkspace(trimmed);
    }
  };

  const targetItems = [
    { id: "main", primary: "Floating bar", secondary: "Default session" },
    ...popouts.map((p) => ({
      id: p.sessionKey,
      primary: p.title || "Pop-out",
      secondary: p.isAILoading ? "Streaming..." : (p.selectedModel || ""),
    })),
  ];

  const modelItems: { id: string; primary: string; secondary?: string }[] =
    (desktopState?.availableModels || []).map((m: AvailableModel) => ({
      id: m.id,
      primary: m.label || m.shortLabel || m.id,
      secondary: m.id,
    }));

  return (
    <div className="flex items-center gap-2 px-4 py-2 border-b border-neutral-800 overflow-x-auto hide-scrollbar">
      {/* New chat */}
      <button
        type="button"
        onClick={onNewChat}
        className="flex items-center gap-1.5 text-xs text-neutral-200 bg-white/[0.06] hover:bg-white/[0.10] border border-white/[0.08] rounded-full px-3 py-1.5 transition-colors shrink-0"
        title="Start a new chat on the floating bar"
      >
        <PlusIcon />
        New chat
      </button>

      {/* New pop-out */}
      <button
        type="button"
        onClick={onNewPopOut}
        className="flex items-center gap-1.5 text-xs text-neutral-300 bg-neutral-800/70 hover:bg-neutral-700 border border-white/[0.06] rounded-full px-3 py-1.5 transition-colors shrink-0"
        title="Open a new chat in a detached pop-out window"
      >
        <PopOutIcon />
        Pop-out
      </button>

      {/* Spacer */}
      <div className="flex-1 min-w-[8px]" />

      {/* Stream target — only show selector if there are pop-outs */}
      {popouts.length > 0 && (
        <div className="flex items-center gap-1 shrink-0">
          <span className="text-[10px] uppercase tracking-wide text-neutral-500 hidden sm:inline">
            Stream to
          </span>
          <Dropdown
            label="Target"
            items={targetItems}
            selectedId={targetSessionKey}
            onSelect={onTargetChange}
          />
        </div>
      )}

      {/* Model picker */}
      {desktopState && (
        <Dropdown
          label="Model"
          items={modelItems}
          selectedId={desktopState.model || null}
          onSelect={onSetModel}
          emptyText={desktopState.modelLabel || "Model"}
        />
      )}

      {/* Workspace input — collapsed by default, expands on click */}
      {desktopState && (
        <input
          type="text"
          value={workspaceDraft}
          onChange={(e) => {
            setWorkspaceEditing(true);
            setWorkspaceDraft(e.target.value);
          }}
          onFocus={() => setWorkspaceEditing(true)}
          onBlur={commitWorkspace}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              (e.target as HTMLInputElement).blur();
            }
            if (e.key === "Escape") {
              setWorkspaceEditing(false);
              setWorkspaceDraft(desktopState.workspace || "");
              (e.target as HTMLInputElement).blur();
            }
          }}
          placeholder="Workspace (path)"
          spellCheck={false}
          autoCorrect="off"
          autoCapitalize="off"
          className="text-xs text-neutral-300 bg-neutral-800/70 hover:bg-neutral-700 focus:bg-neutral-700 border border-white/[0.06] focus:border-white/[0.12] rounded-full px-3 py-1.5 outline-none min-w-[120px] max-w-[200px] transition-colors shrink-0"
          style={{ fontSize: "13px" }}
        />
      )}
    </div>
  );
}
