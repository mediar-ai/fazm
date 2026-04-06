import Cocoa
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
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
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
        textView.invalidateIntrinsicContentSize()
    }
}
