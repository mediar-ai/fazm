"use client";

import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
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

const FolderIcon = ({ className = "" }: { className?: string }) => (
  <svg
    className={className}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="1.8"
    aria-hidden
  >
    <path
      strokeLinecap="round"
      strokeLinejoin="round"
      d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z"
    />
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

/**
 * Portal-rendered popover anchored to a trigger element.
 *
 * The header's control row uses `overflow-x-auto` so the chips can scroll
 * horizontally on narrow phones. That clipping context also clips any absolutely
 * positioned child, which used to swallow the dropdown menus entirely (they open
 * below a ~32px-tall row, so the menu fell outside the clip and was invisible).
 * Rendering into `document.body` with `position: fixed` escapes the clip and any
 * stacking context, so the menu always shows. Position is recomputed from the
 * trigger's bounding rect on open, resize, and scroll.
 */
function DropdownMenu({
  open,
  triggerRef,
  align,
  onClose,
  children,
}: {
  open: boolean;
  triggerRef: React.RefObject<HTMLButtonElement | null>;
  align: "left" | "right";
  onClose: () => void;
  children: React.ReactNode;
}) {
  const menuRef = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState<{ top: number; left: number } | null>(null);

  // Recompute position whenever the menu is open. We always position by `left`
  // (computed from the alignment) and then clamp into the viewport with an 8px
  // margin so a right-aligned panel can never spill off the left edge on a
  // narrow phone. Width is measured from the rendered menu once it mounts.
  useEffect(() => {
    if (!open) {
      setPos(null);
      return;
    }
    const MARGIN = 8;
    const place = () => {
      const trigger = triggerRef.current;
      if (!trigger) return;
      const r = trigger.getBoundingClientRect();
      const menuWidth = menuRef.current?.offsetWidth ?? 280;
      const vw = window.innerWidth;
      let left = align === "right" ? r.right - menuWidth : r.left;
      left = Math.min(Math.max(MARGIN, left), Math.max(MARGIN, vw - menuWidth - MARGIN));
      setPos({ top: r.bottom + 4, left });
    };
    place();
    // Re-run once the portal has rendered so we can measure its real width.
    const raf = requestAnimationFrame(place);
    window.addEventListener("resize", place);
    window.addEventListener("scroll", place, true);
    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", place, true);
    };
  }, [open, align, triggerRef]);

  // Close on outside-click or Escape. The portal lives outside the trigger's DOM
  // subtree, so we explicitly treat clicks inside either the menu or the trigger
  // as "inside".
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      const t = e.target as Node;
      if (menuRef.current?.contains(t)) return;
      if (triggerRef.current?.contains(t)) return;
      onClose();
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
  }, [open, onClose, triggerRef]);

  if (!open || !pos || typeof document === "undefined") return null;

  return createPortal(
    <div
      ref={menuRef}
      style={{
        position: "fixed",
        top: pos.top,
        left: pos.left,
        zIndex: 9999,
      }}
    >
      {children}
    </div>,
    document.body
  );
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
  const triggerRef = useRef<HTMLButtonElement>(null);

  const models: AvailableModel[] = desktopState.availableModels || [];
  const selected = models.find((m) => m.id === desktopState.model);

  // Trigger shows the single-word shortLabel (e.g. "Smart"). Falls back to the
  // desktop-supplied modelLabel for unknown models, and finally a generic stub.
  const triggerText =
    selected?.shortLabel || desktopState.modelLabel || "Model";

  return (
    <div className="relative shrink-0">
      <button
        ref={triggerRef}
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-1.5 text-xs text-neutral-300 bg-neutral-800/70 hover:bg-neutral-700 active:bg-neutral-600 border border-white/[0.06] rounded-full px-3 py-1.5 transition-colors"
        title={selected?.label || "Model"}
      >
        <span className="truncate max-w-[80px]">{triggerText}</span>
        <ChevronIcon open={open} />
      </button>
      <DropdownMenu
        open={open}
        triggerRef={triggerRef}
        align="left"
        onClose={() => setOpen(false)}
      >
        <div className="min-w-[220px] max-w-[300px] bg-neutral-900 border border-white/[0.08] rounded-xl shadow-xl py-1 max-h-[60vh] overflow-y-auto hide-scrollbar">
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
      </DropdownMenu>
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
  const triggerRef = useRef<HTMLButtonElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  // Sync the draft to the upstream workspace whenever the popover opens or the
  // remote value changes (and we aren't actively editing).
  useEffect(() => {
    if (!open) setDraft(desktopState.workspace || "");
  }, [desktopState.workspace, open]);

  // Autofocus the input when the popover opens (desktop only — avoid yanking
  // up the mobile keyboard for a glance). Deferred a frame because the input now
  // lives in a portal that mounts after the position is computed.
  useEffect(() => {
    if (!open) return;
    if (!window.matchMedia("(hover: hover)").matches) return;
    const raf = requestAnimationFrame(() => {
      inputRef.current?.focus();
      inputRef.current?.select();
    });
    return () => cancelAnimationFrame(raf);
  }, [open]);

  const trigger = lastFolderName(desktopState.workspace);
  const fullPath = desktopState.workspace || "Not set";
  const recents = desktopState.recentWorkspaces || [];

  const commit = () => {
    const trimmed = draft.trim();
    if (trimmed !== (desktopState.workspace || "")) {
      onSetWorkspace(trimmed);
    }
    setOpen(false);
  };

  const pick = (path: string) => {
    onSetWorkspace(path);
    setOpen(false);
  };

  return (
    <div className="relative shrink-0">
      <button
        ref={triggerRef}
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-1.5 text-xs text-neutral-300 bg-neutral-800/70 hover:bg-neutral-700 active:bg-neutral-600 border border-white/[0.06] rounded-full px-3 py-1.5 transition-colors"
        title={desktopState.workspace || "Workspace"}
      >
        <span className="truncate max-w-[120px]">{trigger}</span>
        <ChevronIcon open={open} />
      </button>
      <DropdownMenu
        open={open}
        triggerRef={triggerRef}
        align="right"
        onClose={() => setOpen(false)}
      >
        <div className="w-[280px] bg-neutral-900 border border-white/[0.08] rounded-xl shadow-xl overflow-hidden">
          {/* Current workspace */}
          <div className="px-3 pt-3 pb-2">
            <div className="text-[10px] uppercase tracking-wide text-neutral-500 mb-1.5">
              Workspace
            </div>
            <div className="flex items-start gap-2">
              <FolderIcon className="w-3.5 h-3.5 mt-0.5 text-neutral-300 shrink-0" />
              <span className="text-[11px] text-neutral-300 break-all leading-relaxed flex-1 min-w-0">
                {fullPath}
              </span>
            </div>
          </div>

          {/* Recent workspaces — mirrors the pop-out chat's recents list */}
          {recents.length > 0 && (
            <>
              <div className="h-px bg-white/[0.06]" />
              <div className="px-3 pt-2 pb-1 text-[10px] uppercase tracking-wide text-neutral-500">
                Recent
              </div>
              <div className="max-h-[40vh] overflow-y-auto hide-scrollbar pb-1">
                {recents.map((ws) => (
                  <button
                    key={ws.path}
                    type="button"
                    onClick={() => pick(ws.path)}
                    className="w-full text-left px-3 py-2 flex items-center gap-2 text-neutral-300 hover:bg-white/[0.04] transition-colors"
                    title={ws.path}
                  >
                    <FolderIcon className="w-3.5 h-3.5 text-neutral-400 shrink-0" />
                    <span className="flex-1 min-w-0">
                      <span className="block text-xs truncate">{ws.name}</span>
                      <span className="block text-[10px] text-neutral-500 truncate">
                        {ws.path}
                      </span>
                    </span>
                  </button>
                ))}
              </div>
            </>
          )}

          {/* Manual path entry — the web's equivalent of the desktop "Browse…" */}
          <div className="h-px bg-white/[0.06]" />
          <div className="p-3">
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
        </div>
      </DropdownMenu>
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
