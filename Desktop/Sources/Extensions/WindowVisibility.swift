import AppKit
import SwiftUI

// MARK: - Window Visibility Environment Key

/// Whether the NSWindow currently hosting this SwiftUI subtree is visible
/// (not occluded by another window, not in another Space, not minimized).
///
/// Default is `true` so views rendered outside a tracked window (previews,
/// menus, sheets) keep working. Use the `.trackWindowVisibility()` modifier
/// at the root of a window to populate this value.
///
/// Use it to gate `repeatForever` animations:
///
/// ```
/// @Environment(\.fazmWindowIsVisible) private var visible
/// // ...
/// .animation(visible ? .easeInOut(duration: 1).repeatForever(autoreverses: true) : .default, value: state)
/// ```
///
/// Why this exists: SwiftUI's `withAnimation(.repeatForever)` keeps the
/// AttributeGraph dirty every frame, which makes AppKit run a layout pass on
/// every display tick. With several pop-out windows open and the chat-observer
/// pulse, sidebar update glow, and typing indicator all running, prod Fazm was
/// burning ~115% CPU even while idle (Apr 2026). Pausing those animations
/// when the host window is occluded fixes it.
private struct FazmWindowIsVisibleKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var fazmWindowIsVisible: Bool {
        get { self[FazmWindowIsVisibleKey.self] }
        set { self[FazmWindowIsVisibleKey.self] = newValue }
    }
}

// MARK: - Window Accessor

/// Resolves the NSWindow hosting this SwiftUI subtree at runtime. The standard
/// trick of putting an empty `NSViewRepresentable` in the background and
/// reading its `.window` after layout.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            } else {
                // Window may not be attached yet on first layout pass; retry.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let window = view.window { onResolve(window) }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Modifier

/// Attach to the root SwiftUI view of any AppKit-hosted NSWindow. Observes the
/// window's occlusion / miniaturize state and publishes a Bool through the
/// `\.fazmWindowIsVisible` environment value.
private struct TrackWindowVisibilityModifier: ViewModifier {
    @State private var isVisible: Bool = true
    @State private var observerToken: WindowVisibilityObservation? = nil

    func body(content: Content) -> some View {
        content
            .environment(\.fazmWindowIsVisible, isVisible)
            .background(
                WindowAccessor { window in
                    guard observerToken?.window !== window else { return }
                    observerToken = WindowVisibilityObservation(window: window) { newValue in
                        if isVisible != newValue {
                            isVisible = newValue
                        }
                    }
                    // Push initial value through too, in case window started occluded.
                    let initial = Self.computeVisible(for: window)
                    if isVisible != initial { isVisible = initial }
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            )
    }

    fileprivate static func computeVisible(for window: NSWindow) -> Bool {
        let occlusionVisible = window.occlusionState.contains(.visible)
        return occlusionVisible && window.isVisible && !window.isMiniaturized
    }
}

/// Wraps the NotificationCenter observers in a class so we can retain them in
/// `@State` and detach on dealloc.
private final class WindowVisibilityObservation {
    weak var window: NSWindow?
    private var tokens: [NSObjectProtocol] = []

    init(window: NSWindow, onChange: @escaping (Bool) -> Void) {
        self.window = window
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                guard let w = window else { return }
                onChange(TrackWindowVisibilityModifier.computeVisible(for: w))
            }
            tokens.append(token)
        }
    }

    deinit {
        let center = NotificationCenter.default
        for token in tokens { center.removeObserver(token) }
    }
}

extension View {
    /// Publishes the host NSWindow's visibility into `\.fazmWindowIsVisible`.
    /// Apply once at the root SwiftUI view of each NSWindow / Window scene.
    func trackWindowVisibility() -> some View {
        modifier(TrackWindowVisibilityModifier())
    }
}
