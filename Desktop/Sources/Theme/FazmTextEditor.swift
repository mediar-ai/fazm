import Cocoa
import SwiftUI

/// NSTextView subclass that intercepts paste to handle image content.
private class FazmNSTextView: NSTextView {
    var onPasteFiles: (([URL]) -> Void)?
    var onPasteImageData: ((Data) -> Void)?

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general

        // Check for file URLs first
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [
                "public.image", "com.adobe.pdf", "public.plain-text", "public.source-code"
            ]
        ]) as? [URL], !urls.isEmpty {
            onPasteFiles?(urls)
            return
        }

        // Check for image data (e.g. screenshot from clipboard)
        if let data = pb.data(forType: .png) {
            onPasteImageData?(data)
            return
        }
        if let data = pb.data(forType: .tiff) {
            // Convert TIFF to PNG for consistency
            if let rep = NSBitmapImageRep(data: data),
               let pngData = rep.representation(using: .png, properties: [:]) {
                onPasteImageData?(pngData)
                return
            }
        }

        // Fall through to normal text paste
        super.paste(sender)
    }
}

/// NSScrollView subclass that auto-focuses its NSTextView when added to a window.
private class AutoFocusScrollView: NSScrollView {
    var shouldFocusOnAppear = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard shouldFocusOnAppear, let window = self.window,
              let textView = self.documentView as? NSTextView else { return }
        shouldFocusOnAppear = false
        DispatchQueue.main.async {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
        }
    }
}

/// Unified NSTextView wrapper used by both the main chat input and the floating control bar.
struct FazmTextEditor: NSViewRepresentable {
    @Binding var text: String

    // Appearance
    var fontSize: CGFloat = 13
    var textColor: NSColor = .labelColor
    var lineFragmentPadding: CGFloat = 0
    var textContainerInset: NSSize = NSSize(width: 0, height: 8)
    @Environment(\.fontScale) private var fontScale

    // Behavior
    var onSubmit: (() -> Void)? = nil
    var focusOnAppear: Bool = true
    /// Called when user pastes file URLs (images, PDFs, text files)
    var onPasteFiles: (([URL]) -> Void)? = nil
    /// Called when user pastes raw image data (e.g. screenshot)
    var onPasteImageData: ((Data) -> Void)? = nil

    // Optional height tracking (for floating bar's window resize flow)
    var minHeight: CGFloat? = nil
    var maxHeight: CGFloat? = nil
    var onHeightChange: ((CGFloat) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FazmNSTextView()
        let coordinator = context.coordinator
        textView.onPasteFiles = { urls in
            coordinator.onPasteFiles?(urls)
        }
        textView.onPasteImageData = { data in
            coordinator.onPasteImageData?(data)
        }
        let scaledSize = round(fontSize * fontScale)
        textView.font = .systemFont(ofSize: scaledSize)
        textView.textColor = textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(Color(hex: 0x8B5CF6)).withAlphaComponent(0.3),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.delegate = context.coordinator

        textView.textContainer?.lineFragmentPadding = lineFragmentPadding
        textView.textContainerInset = textContainerInset
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView: NSScrollView
        if focusOnAppear {
            let autoFocus = AutoFocusScrollView()
            autoFocus.shouldFocusOnAppear = true
            scrollView = autoFocus
        } else {
            scrollView = NSScrollView()
        }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = .clear
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Keep the coordinator's binding fresh so textDidChange writes to the
        // correct task's draftText when SwiftUI reuses this NSView across tasks.
        context.coordinator.updateTextBinding($text)

        if textView.string != text {
            context.coordinator.isUpdating = true
            textView.string = text
            context.coordinator.isUpdating = false

            // Force layout so NSScrollView knows the new content size
            // (needed for programmatic text changes to show scrollbar)
            if let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                layoutManager.ensureLayout(for: textContainer)
            }

            // When text is cleared (e.g. after submit), scroll back to the top
            // so the empty input isn't left in a scrolled-down position.
            if text.isEmpty {
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            } else {
                // Place cursor at the end so PTT transcripts and other programmatic
                // injections leave the user ready to keep typing or hit Enter.
                let end = (text as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                textView.scrollRangeToVisible(NSRange(location: end, length: 0))
            }

            if onHeightChange != nil {
                context.coordinator.updateHeight(for: textView, scrollView: scrollView)
            }

            // Re-focus the text view when content changes programmatically
            // (e.g. switching between task chats reuses this NSView).
            // Guard: skip if the text view already has focus to avoid a
            // focus-thrash loop with SwiftUI's SelectionOverlay.
            if focusOnAppear, let window = scrollView.window,
               window.firstResponder !== textView {
                DispatchQueue.main.async {
                    guard window.firstResponder !== textView else { return }
                    window.makeFirstResponder(textView)
                }
            }
        }

        // Keep closures fresh so they capture the latest SwiftUI state
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onPasteFiles = onPasteFiles
        context.coordinator.onPasteImageData = onPasteImageData

        let scaledSize = round(fontSize * fontScale)
        let newFont = NSFont.systemFont(ofSize: scaledSize)
        if textView.font != newFont {
            textView.font = newFont
        }
    }

    /// Return a concrete size to SwiftUI's layout engine so it doesn't have to
    /// recurse through the parent hierarchy to infer the editor's height.
    /// Without this, NSViewRepresentable reports no intrinsic size and SwiftUI
    /// keeps propagating unconstrained proposals upward, contributing to the
    /// recursive StackLayout sizing loop seen in the task chat panel.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let minH = minHeight, let _ = maxHeight else {
            return nil  // no height tracking — let SwiftUI use default NSView sizing
        }
        // Use the coordinator's cached height instead of calling ensureLayout here.
        // Calling ensureLayout during SwiftUI's layout pass can trigger NSScrollView
        // frame changes → constraint updates → recursive layout invalidation → crash.
        let cachedHeight = context.coordinator.lastHeight
        let height = cachedHeight > 0 ? cachedHeight : minH
        return CGSize(width: proposal.width ?? nsView.bounds.width, height: height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            minHeight: minHeight,
            maxHeight: maxHeight,
            onHeightChange: onHeightChange
        )
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onSubmit: (() -> Void)?
        var onPasteFiles: (([URL]) -> Void)?
        var onPasteImageData: ((Data) -> Void)?
        var isUpdating = false

        func updateTextBinding(_ binding: Binding<String>) {
            _text = binding
        }

        // Height tracking (only used when onHeightChange is provided)
        private let minHeight: CGFloat?
        private let maxHeight: CGFloat?
        private let onHeightChange: ((CGFloat) -> Void)?
        /// Last computed content height — read by sizeThatFits to avoid
        /// calling ensureLayout during SwiftUI's layout pass.
        var lastHeight: CGFloat = 0

        init(
            text: Binding<String>,
            onSubmit: (() -> Void)?,
            minHeight: CGFloat?,
            maxHeight: CGFloat?,
            onHeightChange: ((CGFloat) -> Void)?
        ) {
            self._text = text
            self.onSubmit = onSubmit
            self.minHeight = minHeight
            self.maxHeight = maxHeight
            self.onHeightChange = onHeightChange
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView = notification.object as? NSTextView else { return }
            self.text = textView.string

            if onHeightChange != nil, let scrollView = textView.enclosingScrollView {
                updateHeight(for: textView, scrollView: scrollView)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if !flags.contains(.shift) {
                    onSubmit?()
                    return true
                }
            }
            return false
        }

        func updateHeight(for textView: NSTextView, scrollView: NSScrollView) {
            guard let onHeightChange = onHeightChange,
                  let minH = minHeight, let maxH = maxHeight,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else { return }

            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let contentHeight = usedRect.height + textView.textContainerInset.height * 2
            let constrainedHeight = min(max(contentHeight, minH), maxH)

            if abs(constrainedHeight - lastHeight) > 1 {
                lastHeight = constrainedHeight
                // Defer to avoid recursive layout: onHeightChange updates SwiftUI
                // state, which must not happen during an active layout/display cycle.
                DispatchQueue.main.async {
                    onHeightChange(constrainedHeight)
                }
            }
        }
    }
}
