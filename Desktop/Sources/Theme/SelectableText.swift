import Cocoa
import ObjCExceptionCatcher
import SwiftUI

/// NSTextView subclass that reports its layout height as intrinsicContentSize
/// so SwiftUI can size the container correctly.
class AutoSizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager = layoutManager, let textContainer = textContainer else {
            return super.intrinsicContentSize
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(usedRect.height + textContainerInset.height * 2))
    }

    override func didChangeText() {
        super.didChangeText()
        // Skip when detached — propagating up to a torn-down NSWindow
        // raises NSInternalInconsistencyException from _postWindowNeedsUpdateConstraints.
        // Crash repro: 2026-05-21 prod 11:09 with 5+ streaming popouts + context compaction.
        guard window != nil, superview != nil else { return }
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        guard window != nil, superview != nil else { return }
        invalidateIntrinsicContentSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // updateNSView applies text even while detached (so content is never lost),
        // but skips the size invalidation when detached. Re-invalidate on attach so
        // SwiftUI re-queries our intrinsic size and the text becomes visible.
        guard window != nil, superview != nil else { return }
        invalidateIntrinsicContentSize()
    }

    // Don't show NSTextView's default context menu — let SwiftUI's .contextMenu handle it
    override func menu(for event: NSEvent) -> NSMenu? {
        return nil
    }

    // Pass right-clicks through to the parent so SwiftUI context menus work
    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }
}

/// A read-only selectable text view with visible selection highlighting.
/// Use instead of `Text(...).textSelection(.enabled)` when the default
/// selection color is invisible (e.g. vibrantLight floating bar).
struct SelectableText: NSViewRepresentable {
    let text: String
    var fontSize: CGFloat = 13
    var textColor: NSColor = .labelColor
    var lineLimit: Int? = nil
    @Environment(\.fontScale) private var fontScale

    func makeNSView(context: Context) -> AutoSizingTextView {
        let scaledSize = round(fontSize * fontScale)
        let textView = AutoSizingTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: scaledSize)
        textView.textColor = textColor
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(Color(hex: 0x8B5CF6)).withAlphaComponent(0.3),
            .foregroundColor: NSColor.labelColor,
        ]
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        if let lineLimit {
            textView.textContainer?.maximumNumberOfLines = lineLimit
            textView.textContainer?.lineBreakMode = .byTruncatingTail
        }
        return textView
    }

    func updateNSView(_ textView: AutoSizingTextView, context: Context) {
        // Always apply content, even when detached. SwiftUI re-runs updateNSView on a
        // freshly mounted representable before its window attachment completes (e.g. a
        // finished AI message re-mounting after streaming); if we bailed here the text
        // would never be set and the message would render blank.
        let scaledSize = round(fontSize * fontScale)
        if textView.string != text {
            textView.string = text
        }
        textView.font = .systemFont(ofSize: scaledSize)
        textView.textColor = textColor
        if let lineLimit {
            textView.textContainer?.maximumNumberOfLines = lineLimit
            textView.textContainer?.lineBreakMode = .byTruncatingTail
        } else {
            textView.textContainer?.maximumNumberOfLines = 0
            textView.textContainer?.lineBreakMode = .byWordWrapping
        }
        // Only invalidate the intrinsic size when attached. On a detached/torn-down
        // window this propagates to _postWindowNeedsUpdateConstraints and throws
        // NSException → SIGABRT. viewDidMoveToWindow re-invalidates once attached.
        guard textView.window != nil, textView.superview != nil else { return }
        if let exc = ObjCExceptionCatcher.catching({ textView.invalidateIntrinsicContentSize() }) {
            log("SelectableText: NSException during invalidateIntrinsicContentSize — \(exc.name.rawValue): \(exc.reason ?? "nil")")
        }
    }
}
