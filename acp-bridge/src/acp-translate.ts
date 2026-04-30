// Stub for the Codex query path — author of commit 73756790 imported this
// module from codex-query.ts but did not commit the file. Restored as a
// no-op so the bridge compiles. Replace with the real implementation when
// the Codex path is wired up; this stub only affects users on Codex models
// (Claude queries never enter handleCodexQuery).

import type { OutboundMessage } from "./protocol.js";

export interface TranslatorState {
  sessionId: string;
  collectedText: string;
  pendingBoundary: boolean;
  sendWithSession: (sessionId: string | undefined, msg: OutboundMessage) => void;
}

export function translateCodexUpdate(
  _params: Record<string, unknown>,
  _state: TranslatorState,
): void {
  // No-op stub. Real translation logic should arrive in a follow-up commit.
}
