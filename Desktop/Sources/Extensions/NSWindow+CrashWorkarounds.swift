// NSWindow+CrashWorkarounds.swift
//
// Mitigations for FAZM-20: EXC_BAD_ACCESS in NSConcreteMapTable dealloc inside
// __NSTouchBarFinderSetNeedsUpdateOnMain_block_invoke_2.
//
// Stack on every report is 100% AppKit/QuartzCore/CoreFoundation, zero Fazm code.
// Fazm has no NSTouchBar code, but AppKit auto-creates touch bars for every window
// and the auto-create path keeps weak references to views in an internal NSMapTable.
// Heavy window churn (floating bar + popouts + overlays + toasts) appears to be
// triggering the bad-access on dealloc.
//
// First seen 2026-03-29; 83 affected users in 30 days; still firing on 2.4.1.
//
// Mitigation: opt every window out of the auto touch bar machinery and disable
// window tabbing (cheap, reversible, no UX impact since TouchBar usage is near zero
// on the macs Fazm runs on).

import AppKit

extension NSWindow {
    /// Apply once at app launch (in `applicationDidFinishLaunching`).
    /// - Disables window tabbing globally, which removes a chunk of AppKit's
    ///   internal weak-ref bookkeeping that intersects the same map tables.
    /// - Hides the "Customize Touch Bar..." menu item so AppKit doesn't synthesize
    ///   one when the user chooses View > Customize Toolbar.
    /// - Installs a notification observer that applies per-window mitigations to
    ///   every NSWindow as it becomes visible (covers SwiftUI-managed windows
    ///   we don't construct ourselves).
    static func applyAppGlobalCrashWorkarounds() {
        NSWindow.allowsAutomaticWindowTabbing = false
        if #available(macOS 10.12.2, *) {
            NSApplication.shared.isAutomaticCustomizeTouchBarMenuItemEnabled = false
        }

        let center = NotificationCenter.default
        // Catch the first time any window is shown — covers SwiftUI Window scenes.
        center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            (note.object as? NSWindow)?.applyCrashWorkarounds()
        }
        center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { note in
            (note.object as? NSWindow)?.applyCrashWorkarounds()
        }
    }

    /// Apply on every NSWindow / NSPanel we explicitly construct.
    /// Idempotent — safe to call repeatedly.
    func applyCrashWorkarounds() {
        // Disallow tabbing on this specific window (cheap; redundant with the
        // class-level setter but defensive against future regressions).
        self.tabbingMode = .disallowed

        // Disable AppKit's automatic touch bar for this window. The setter is
        // public on NSResponder but Swift doesn't surface it as a stored Swift
        // property in older SDKs in some build configurations, so we go through
        // KVC for portability.
        if responds(to: Selector(("setAutomaticallyCustomizesTouchBar:"))) {
            setValue(false, forKey: "automaticallyCustomizesTouchBar")
        }
    }
}
