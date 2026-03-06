import AppKit
import SwiftUI

// MARK: - Plain-Text Copy NSTextView

/// NSTextView subclass that always copies plain text (no RTF/rich formatting).
fileprivate class PlainCopyNSTextView: NSTextView {
    override func copy(_ sender: Any?) {
        guard let storage = textStorage, selectedRange().length > 0 else { return }
        let plain = storage.attributedSubstring(from: selectedRange()).string
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plain, forType: .string)
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return super.intrinsicContentSize
        }
        lm.ensureLayout(for: tc)
        let rect = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(rect.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Width changed → text reflows → height changes
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

/// SwiftUI wrapper for NSTextView that supports text selection but copies only plain text.
struct PlainCopyText: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let tv = PlainCopyNSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        if #available(macOS 15.1, *) {
            tv.writingToolsBehavior = .none
        }
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        // Only update if content actually changed to avoid layout thrashing
        if tv.textStorage?.string != attributedString.string {
            tv.textStorage?.setAttributedString(attributedString)
            tv.invalidateIntrinsicContentSize()
        }
    }
}

// MARK: - Compact Code Blocks Environment Key

private struct CompactCodeBlocksKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var compactCodeBlocks: Bool {
        get { self[CompactCodeBlocksKey.self] }
        set { self[CompactCodeBlocksKey.self] = newValue }
    }
}

/// A markdown text view that supports text selection across paragraph breaks.
///
/// Splits content into text segments and code blocks:
/// - Text segments render as a single `Text(AttributedString)` so selection
///   works across paragraphs, bold, italic, etc.
/// - Code blocks render with proper monospace font and background box.
///
/// This replaces MarkdownUI's `Markdown` which creates separate views per
/// block element and breaks cross-paragraph selection.
struct SelectableMarkdown: View {
    let text: String
    let sender: ChatSender
    @Environment(\.fontScale) private var fontScale
    @Environment(\.compactCodeBlocks) private var compactCodeBlocks

    // Cached parsed segments — pre-computed on init, recomputed only when text changes.
    // Avoids running splitSegments() on every SwiftUI layout pass.
    @State private var cachedSegments: [Segment]

    // Cached NSAttributedStrings keyed by segment content.
    // Populated on first appear; reused on subsequent renders.
    @State private var attrCache: [String: NSAttributedString?] = [:]
    // Font scale at time of caching — used to invalidate when scale changes.
    @State private var cachedFontScale: CGFloat = 0

    init(text: String, sender: ChatSender) {
        self.text = text
        self.sender = sender
        self._cachedSegments = State(initialValue: Self.splitSegments(text))
    }

    var body: some View {
        Group {
            if cachedSegments.count == 1, case .text = cachedSegments[0].kind {
                // Single text segment — no VStack overhead
                textView(cachedSegments[0].content)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cachedSegments) { segment in
                        switch segment.kind {
                        case .text:
                            textView(segment.content)
                        case .codeBlock:
                            codeBlockView(segment.content)
                        }
                    }
                }
            }
        }
        .onChange(of: text) { _, newText in
            cachedSegments = Self.splitSegments(newText)
            attrCache.removeAll()
        }
        .onChange(of: fontScale) {
            // Font scale changed — cached attributed strings are stale
            attrCache.removeAll()
            cachedFontScale = 0
        }
    }

    // MARK: - Text Segment (selectable across paragraphs)

    @ViewBuilder
    private func textView(_ content: String) -> some View {
        let fontSize = round(14 * fontScale)
        // Use cached NSAttributedString if available for the current font scale
        let styled: NSAttributedString? = {
            if cachedFontScale == fontScale, let cached = attrCache[content] {
                return cached
            }
            let processed = Self.preprocessText(content)
            return Self.styledNSAttributedString(
                from: processed, sender: sender, fontSize: fontSize, fontScale: fontScale
            )
        }()

        Group {
            if let s = styled {
                PlainCopyText(attributedString: s)
            } else {
                let baseColor: NSColor = sender == .user ? .white : NSColor(FazmColors.textPrimary)
                let fallbackAttr = NSAttributedString(
                    string: content,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: fontSize),
                        .foregroundColor: baseColor,
                    ]
                )
                PlainCopyText(attributedString: fallbackAttr)
            }
        }
        .onAppear {
            // Populate cache on first appearance so future renders skip computation
            if cachedFontScale != fontScale {
                attrCache.removeAll()
                cachedFontScale = fontScale
            }
            if attrCache[content] == nil {
                attrCache[content] = styled
            }
        }
    }

    // MARK: - Code Block (boxed, monospace)

    @ViewBuilder
    private func codeBlockView(_ code: String) -> some View {
        if compactCodeBlocks {
            CollapsibleCodeBlockView(code: code, sender: sender, fontScale: fontScale)
        } else {
            let codeFontSize = round(13 * fontScale)
            let bgColor = sender == .user
                ? Color.white.opacity(0.15)
                : FazmColors.backgroundTertiary
            let codeColor: NSColor = sender == .user ? .white : NSColor(FazmColors.textPrimary)
            let codeAttr = NSAttributedString(
                string: code,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular),
                    .foregroundColor: codeColor,
                ]
            )

            ScrollView(.horizontal, showsIndicators: false) {
                PlainCopyText(attributedString: codeAttr)
            }
            .padding(12)
            .background(bgColor)
            .cornerRadius(8)
        }
    }

    // MARK: - Attributed String Styling

    /// Builds an NSAttributedString with proper AppKit types (NSColor, NSFont) for use in NSTextView.
    private static func styledNSAttributedString(
        from processed: String, sender: ChatSender, fontSize: CGFloat, fontScale: CGFloat
    ) -> NSAttributedString? {
        guard let attributed = try? AttributedString(
            markdown: processed,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else { return nil }

        let codeFontSize = round(13 * fontScale)
        let baseColor: NSColor = sender == .user ? .white : NSColor(FazmColors.textPrimary)
        let linkColor: NSColor = sender == .user
            ? NSColor.white.withAlphaComponent(0.9)
            : NSColor(FazmColors.purplePrimary)
        let codeBgColor: NSColor = sender == .user
            ? NSColor.white.withAlphaComponent(0.15)
            : NSColor(FazmColors.backgroundTertiary)
        let baseFont = NSFont.systemFont(ofSize: fontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: fontSize)
        let codeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)

        let result = NSMutableAttributedString()

        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: baseColor,
                .font: baseFont,
            ]

            // Handle inline presentation intents (bold, italic, code, strikethrough)
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    attrs[.font] = codeFont
                    attrs[.backgroundColor] = codeBgColor
                } else if intent.contains(.stronglyEmphasized) && intent.contains(.emphasized) {
                    // Bold + Italic
                    if let boldItalic = NSFont.systemFont(ofSize: fontSize, weight: .bold)
                        .withTraits(.italicFontMask) {
                        attrs[.font] = boldItalic
                    } else {
                        attrs[.font] = boldFont
                    }
                } else if intent.contains(.stronglyEmphasized) {
                    attrs[.font] = boldFont
                } else if intent.contains(.emphasized) {
                    if let italic = NSFont.systemFont(ofSize: fontSize, weight: .regular)
                        .withTraits(.italicFontMask) {
                        attrs[.font] = italic
                    }
                }
                if intent.contains(.strikethrough) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }

            // Handle links
            if let url = run.link {
                attrs[.foregroundColor] = linkColor
                attrs[.link] = url
                if sender == .user {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            }

            result.append(NSAttributedString(string: text, attributes: attrs))
        }

        return result
    }

    // MARK: - Markdown Preprocessing

    /// Converts block-level elements (headers, asterisk lists) into inline-compatible
    /// form for `AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace`.
    private static func preprocessText(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            var processed = line

            // Convert headers to bold text
            if let match = processed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let headerText = String(processed[match.upperBound...])
                processed = "**\(headerText)**"
            }

            // Convert "* item" to "• item" so asterisks aren't parsed as italic
            processed = processed.replacingOccurrences(
                of: #"^(\s*)\* "#,
                with: "$1• ",
                options: .regularExpression
            )

            return processed
        }.joined(separator: "\n")
    }

    // MARK: - Segment Splitting

    enum SegmentKind: Equatable {
        case text
        case codeBlock(language: String?)
    }

    struct Segment: Identifiable {
        let id: Int
        let kind: SegmentKind
        let content: String
    }

    /// Splits markdown into alternating text and code block segments.
    static func splitSegments(_ text: String) -> [Segment] {
        var segments = [Segment]()
        var currentText = ""
        var inCodeBlock = false
        var codeBlockLines = [String]()
        var codeLanguage: String?
        var nextId = 0

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    // End of code block — flush accumulated text first, then add code block
                    let textContent = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !textContent.isEmpty {
                        segments.append(Segment(id: nextId, kind: .text, content: textContent))
                        nextId += 1
                        currentText = ""
                    }

                    let code = codeBlockLines.joined(separator: "\n")
                    segments.append(Segment(id: nextId, kind: .codeBlock(language: codeLanguage), content: code))
                    nextId += 1
                    codeBlockLines = []
                    codeLanguage = nil
                } else {
                    // Start of code block — flush accumulated text
                    let textContent = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !textContent.isEmpty {
                        segments.append(Segment(id: nextId, kind: .text, content: textContent))
                        nextId += 1
                        currentText = ""
                    }

                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = lang.isEmpty ? nil : lang
                }
                inCodeBlock.toggle()
                continue
            }

            if inCodeBlock {
                codeBlockLines.append(line)
            } else {
                if !currentText.isEmpty {
                    currentText += "\n"
                }
                currentText += line
            }
        }

        // Flush remaining content
        if inCodeBlock {
            // Unclosed code block — treat accumulated code as text
            currentText += "\n```" + (codeLanguage ?? "")
            for line in codeBlockLines {
                currentText += "\n" + line
            }
        }

        let remaining = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            segments.append(Segment(id: nextId, kind: .text, content: remaining))
        }

        return segments
    }
}

// MARK: - Collapsible Code Block (for floating bar)

/// Code block that collapses to 5 lines with a copy button.
/// Used in the floating control bar to keep responses compact.
struct CollapsibleCodeBlockView: View {
    let code: String
    let sender: ChatSender
    let fontScale: CGFloat

    @State private var isExpanded = false
    @State private var showCopied = false

    private let maxCollapsedLines = 5

    private var lines: [String] { code.components(separatedBy: "\n") }
    private var needsCollapsing: Bool { lines.count > maxCollapsedLines }
    private var displayedCode: String {
        if isExpanded || !needsCollapsing {
            return code
        }
        return lines.prefix(maxCollapsedLines).joined(separator: "\n")
    }

    var body: some View {
        let codeFontSize = round(13 * fontScale)
        let bgColor = sender == .user
            ? Color.white.opacity(0.15)
            : FazmColors.backgroundTertiary

        VStack(alignment: .leading, spacing: 0) {
            let codeColor: NSColor = sender == .user ? .white : NSColor(FazmColors.textPrimary)
            let codeAttr = NSAttributedString(
                string: displayedCode,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular),
                    .foregroundColor: codeColor,
                ]
            )
            ScrollView(.horizontal, showsIndicators: false) {
                PlainCopyText(attributedString: codeAttr)
            }
            .padding(.top, 12)
            .padding(.horizontal, 12)
            .padding(.bottom, needsCollapsing && !isExpanded ? 4 : 12)

            // Bottom bar with expand/collapse + copy
            HStack(spacing: 8) {
                if needsCollapsing {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                        HStack(spacing: 3) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9))
                            Text(isExpanded ? "Show less" : "\(lines.count - maxCollapsedLines) more lines")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button(action: copyCode) {
                    HStack(spacing: 3) {
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(showCopied ? "Copied" : "Copy")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(showCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(bgColor)
        .cornerRadius(8)
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }
}

// MARK: - NSFont Trait Helper

private extension NSFont {
    func withTraits(_ traits: NSFontTraitMask) -> NSFont? {
        NSFontManager.shared.convert(self, toHaveTrait: traits)
    }
}
