import Foundation

/// Single source of truth for the user-facing copy shown ABOVE the
/// `PersonalAccountChooserSheet` trigger button on every surface
/// (onboarding banner, floating-bar AI message, popout, etc.).
///
/// Previously each call site rewrote these strings inline, and the
/// `geminiAvailable` branching drifted between surfaces. That caused the
/// May 2026 Sayan bug: onboarding's `.claudeAuthRequired` copy still said
/// "Claude Code or ChatGPT" even after the floating-bar copy was updated
/// to mention Gemini.
///
/// Anytime new copy lands here, every surface picks it up for free.
enum AccountErrorReason {
    /// Built-in credit cap reached. User must switch provider to keep chatting.
    case creditExhausted

    /// Personal-mode session is missing/invalid auth (e.g. Claude Code token
    /// expired, Codex session not connected). User must connect or pick a
    /// different provider.
    case authRequired
}

enum AccountErrorSurface {
    /// Onboarding chat — copy ends with "to continue setup."
    case onboarding

    /// Live floating-bar conversation — copy ends with "to keep chatting."
    case chat
}

enum AccountErrorCopy {
    /// Returns the message displayed above the "Connect Personal Account"
    /// button. Always branches on `geminiAvailable` so that whenever Gemini
    /// is reachable the user is told it's a free option.
    static func message(
        reason: AccountErrorReason,
        surface: AccountErrorSurface,
        geminiAvailable: Bool
    ) -> String {
        let tail: String
        switch surface {
        case .onboarding: tail = "to continue setup."
        case .chat:       tail = "to keep chatting."
        }

        switch reason {
        case .creditExhausted:
            if geminiAvailable {
                return "You've used all your built-in AI credits. Switch to Gemini for free, or connect your Claude Code or ChatGPT account \(tail)"
            } else {
                return "You've used all your built-in AI credits. Connect your Claude Code or ChatGPT account \(tail)"
            }
        case .authRequired:
            if geminiAvailable {
                return "Switch to Gemini for free, or connect your Claude Code or ChatGPT account \(tail)"
            } else {
                return "Please connect your Claude Code or ChatGPT account \(tail)"
            }
        }
    }
}
