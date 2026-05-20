"use client";

import { useEffect, useRef, useState } from "react";
import {
  type AvailableModel,
  type DesktopState,
} from "@/lib/useDesktopRelay";

interface Props {
  desktopState: DesktopState | null;
  onSetModel: (id: string) => void;
  onSetWorkspace: (path: string) => void;
}

/* ------------------------------------------------------------------ */
/*  Tiny inline icons                                                 */
/* ------------------------------------------------------------------ */

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
/*  Helpers                                                           */
/* ------------------------------------------------------------------ */

/** Last non-empty segment of a slash-separated path, with a sane fallback. */
function lastFolderName(path: string, fallback = "Workspace"): string {
  if (!path) return fallback;
  const parts = path.split("/").filter(Boolean);
  return parts[parts.length - 1] || fallback;
}

/** Hook: close popover on outside-click or Escape. */
function useDismissable(open: boolean, onClose: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) onClose();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("mousedown", onClick);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onClick);
      document.removeEventListener("keydown", onKey);
    };
  }, [open, onClose]);
  return ref;
}

/* ------------------------------------------------------------------ */
/*  Model dropdown — trigger shows shortLabel, popover shows full     */
/* ------------------------------------------------------------------ */

function ModelDropdown({
  desktopState,
  onSetModel,
}: {
  desktopState: DesktopState;
  onSetModel: (id: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const ref = useDismissable(open, () => setOpen(false));

  const models: AvailableModel[] = desktopState.availableModels || [];
  const selected = models.find((m) => m.id === desktopState.model);

  // Trigger shows the single-word shortLabel (e.g. "Smart"). Falls back to the
  // desktop-supplied modelLabel for unknown models, and finally a generic stub.
  const triggerText =
    selected?.shortLabel || desktopState.modelLabel || "Model";

  return (
    <div ref={ref} className="relative shrink-0">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-1.5 text-xs text-neutral-300 bg-neutral-800/70 hover:bg-neutral-700 active:bg-neutral-600 border border-white/[0.06] rounded-full px-3 py-1.5 transition-colors"
        title={selected?.label || "Model"}
      >
        <span className="truncate max-w-[80px]">{triggerText}</span>
        <ChevronIcon open={open} />
      </button>
      {open && (
        <div className="absolute left-0 top-full mt-1 z-30 min-w-[220px] max-w-[300px] bg-neutral-900 border border-white/[0.08] rounded-xl shadow-xl py-1 max-h-[60vh] overflow-y-auto hide-scrollbar">
          {models.length === 0 ? (
            <div className="px-3 py-2 text-xs text-neutral-500">
              Loading models…
            </div>
          ) : (
            models.map((m) => {
              const active = m.id === desktopState.model;
              return (
                <button
                  key={m.id}
                  type="button"
                  onClick={() => {
                    onSetModel(m.id);
                    setOpen(false);
                  }}
                  className={`w-full text-left px-3 py-2 text-xs transition-colors flex items-start gap-2 ${
                    active
                      ? "bg-white/[0.06] text-white"
                      : "text-neutral-300 hover:bg-white/[0.04]"
                  }`}
                >
                  <span
                    className={`mt-1 w-1.5 h-1.5 rounded-full shrink-0 ${
                      active ? "bg-green-400" : "bg-transparent"
                    }`}
                  />
                  <span className="flex-1 min-w-0">
                    <span className="block truncate">
                      {m.label || m.shortLabel || m.id}
                    </span>
                    <span className="block text-[10px] text-neutral-500 truncate">
                      {m.id}
                    </span>
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
/*  Workspace dropdown — trigger shows last folder, popover lets you  */
/*  see the full path and edit it.                                    */
/* ------------------------------------------------------------------ */

function WorkspaceDropdown({
  desktopState,
  onSetWorkspace,
}: {
  desktopState: DesktopState;
  onSetWorkspace: (path: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [draft, setDraft] = useState(desktopState.workspace || "");
  const ref = useDismissable(open, () => setOpen(false));
  const inputRef = useRef<HTMLInputElement>(null);

  // Sync the draft to the upstream workspace whenever the popover opens or the
  // remote value changes (and we aren't actively editing).
  useEffect(() => {
    if (!open) setDraft(desktopState.workspace || "");
  }, [desktopState.workspace, open]);

  // Autofocus the input when the popover opens (desktop only — avoid yanking
  // up the mobile keyboard for a glance).
  useEffect(() => {
    if (!open) return;
    if (window.matchMedia("(hover: hover)").matches) {
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [open]);

  const trigger = lastFolderName(desktopState.workspace);
  const fullPath = desktopState.workspace || "Not set";

  const commit = () => {
    const trimmed = draft.trim();
    if (trimmed !== (desktopState.workspace || "")) {
      onSetWorkspace(trimmed);
    }
    setOpen(false);
  };

  return (
    <div ref={ref} className="relative shrink-0">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-1.5 text-xs text-neutral-300 bg-neutral-800/70 hover:bg-neutral-700 active:bg-neutral-600 border border-white/[0.06] rounded-full px-3 py-1.5 transition-colors"
        title={desktopState.workspace || "Workspace"}
      >
        <span className="truncate max-w-[120px]">{trigger}</span>
        <ChevronIcon open={open} />
      </button>
      {open && (
        <div className="absolute right-0 top-full mt-1 z-30 w-[280px] bg-neutral-900 border border-white/[0.08] rounded-xl shadow-xl p-3">
          <div className="text-[10px] uppercase tracking-wide text-neutral-500 mb-1">
            Workspace
          </div>
          <div className="text-[11px] text-neutral-400 break-all mb-2 leading-relaxed">
            {fullPath}
          </div>
          <input
            ref={inputRef}
            type="text"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                commit();
              }
              if (e.key === "Escape") {
                e.preventDefault();
                setOpen(false);
              }
            }}
            placeholder="/path/to/folder"
            spellCheck={false}
            autoCorrect="off"
            autoCapitalize="off"
            className="w-full bg-neutral-800 text-white text-xs rounded-lg px-2.5 py-1.5 border border-white/[0.06] focus:border-white/[0.12] outline-none placeholder:text-neutral-600"
            style={{ fontSize: "13px" }}
          />
          <div className="flex justify-end gap-2 mt-2">
            <button
              type="button"
              onClick={() => setOpen(false)}
              className="text-[11px] text-neutral-400 hover:text-neutral-200 px-2 py-1 rounded-md transition-colors"
            >
              Cancel
            </button>
            <button
              type="button"
              onClick={commit}
              className="text-[11px] text-white bg-white/[0.10] hover:bg-white/[0.16] border border-white/[0.08] px-2.5 py-1 rounded-md transition-colors"
            >
              Set
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/*  Main controls bar — inline chips, designed to live inside the     */
/*  header row alongside the hamburger and account controls.          */
/* ------------------------------------------------------------------ */

export default function ChatControls({
  desktopState,
  onSetModel,
  onSetWorkspace,
}: Props) {
  if (!desktopState) return null;

  return (
    <div className="flex items-center gap-2 min-w-0 overflow-x-auto hide-scrollbar">
      <ModelDropdown desktopState={desktopState} onSetModel={onSetModel} />
      <WorkspaceDropdown
        desktopState={desktopState}
        onSetWorkspace={onSetWorkspace}
      />
    </div>
  );
}
