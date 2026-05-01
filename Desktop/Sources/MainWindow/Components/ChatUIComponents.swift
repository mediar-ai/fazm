import SwiftUI
import MarkdownUI

// MARK: - Content Block Grouping

/// Groups consecutive content blocks of the same type for rendering
enum ContentBlockGroup: Identifiable, Equatable {
    case text(id: String, text: String)
    case toolCalls(id: String, calls: [ToolCallGroupItem])
    case thinking(id: String, text: String)
    case discoveryCard(id: String, title: String, summary: String, fullText: String)
    case observerCard(id: String, activityId: Int64, type: String, content: String, buttons: [ObserverCardButton], actedAction: String? = nil)

/// Equatable wrapper for tool call data in a group.
struct ToolCallGroupItem: Equatable, Identifiable {
    var id: String { toolUseId ?? name }
    let name: String
    let status: ToolCallStatus
    let toolUseId: String?
    let input: ToolCallInput?
    let output: String?
}

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .toolCalls(let id, _): return id
        case .thinking(let id, _): return id
        case .discoveryCard(let id, _, _, _): return id
        case .observerCard(let id, _, _, _, _, _): return id
        }
    }

    /// Groups consecutive content blocks into display groups.
    ///
    /// `hiddenToolNames` lists tool names the caller renders separately (e.g. `ask_followup`
    /// in onboarding, whose question/buttons are drawn outside the message stream). When a
    /// run of tool calls between two text blocks is composed entirely of hidden tools, the
    /// grouper drops them and merges the surrounding text into a single bubble so a thought
    /// that the model split around a hidden tool doesn't render as two orphan fragments.
    static func group(_ blocks: [ChatContentBlock], hiddenToolNames: Set<String> = []) -> [ContentBlockGroup] {
        var result: [ContentBlockGroup] = []
        var pendingText = ""
        var pendingTextId = ""
        var pendingToolCalls: [ToolCallGroupItem] = []
        var pendingToolCallsId = ""

        func flushText() {
            if !pendingText.isEmpty {
                result.append(.text(id: pendingTextId, text: pendingText))
                pendingText = ""
                pendingTextId = ""
            }
        }

        func flushToolCalls() {
            if !pendingToolCalls.isEmpty {
                result.append(.toolCalls(id: pendingToolCallsId, calls: pendingToolCalls))
                pendingToolCalls = []
                pendingToolCallsId = ""
            }
        }

        for block in blocks {
            switch block {
            case .text(let id, let text):
                if !pendingToolCalls.isEmpty {
                    let allHidden = pendingToolCalls.allSatisfy { hiddenToolNames.contains($0.name) }
                    if allHidden {
                        // Drop the hidden tool calls so pending text merges with this text.
                        pendingToolCalls = []
                        pendingToolCallsId = ""
                    } else {
                        flushText()
                        flushToolCalls()
                    }
                }
                if pendingText.isEmpty {
                    pendingTextId = id
                }
                pendingText += (pendingText.isEmpty ? "" : "\n\n") + text

            case .toolCall(let id, let name, let status, let toolUseId, let input, let output):
                // Defer text flush: if the next block is more text and every tool in this
                // run is hidden, we'll merge the text across them.
                if pendingToolCalls.isEmpty {
                    pendingToolCallsId = id
                }
                pendingToolCalls.append(ToolCallGroupItem(name: name, status: status, toolUseId: toolUseId, input: input, output: output))

            case .thinking(let id, let text):
                flushText()
                flushToolCalls()
                result.append(.thinking(id: id, text: text))

            case .discoveryCard(let id, let title, let summary, let fullText):
                flushText()
                flushToolCalls()
                result.append(.discoveryCard(id: id, title: title, summary: summary, fullText: fullText))

            case .observerCard(let id, let activityId, let type, let content, let buttons, let actedAction):
                flushText()
                flushToolCalls()
                result.append(.observerCard(id: id, activityId: activityId, type: type, content: content, buttons: buttons, actedAction: actedAction))
            }
        }

        flushText()
        flushToolCalls()
        return result
    }
}

// MARK: - Tool Calls Group View

struct ToolCallsGroup: View {
    let calls: [ContentBlockGroup.ToolCallGroupItem]
    @State private var isExpanded = false

    /// The currently running call, or the last call if all completed
    private var latestCall: ContentBlockGroup.ToolCallGroupItem? {
        calls.last(where: { $0.status == .running }) ?? calls.last
    }

    private var hasRunningCalls: Bool {
        calls.contains(where: { $0.status == .running })
    }

    /// Human-readable header label — uses action verb when single call, count when multiple
    private var headerLabel: String {
        if calls.count == 1, let call = calls.first {
            return ChatContentBlock.displayName(for: call.name)
        }
        return "\(calls.count) actions"
    }

    /// Detail text shown next to the header label
    private var headerDetail: String {
        if calls.count == 1, let call = calls.first {
            return call.input?.summary ?? ""
        }
        return inlineSummary
    }

    /// One-line inline summary: shows what's happening right now
    private var inlineSummary: String {
        guard let call = latestCall else { return "" }
        if call.status == .running {
            return call.input?.summary ?? call.name
        } else if let output = call.output, !output.isEmpty {
            // Show first meaningful line of output, stripping markdown fences
            let firstLine = output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first(where: { !$0.hasPrefix("```") })
                .map(String.init) ?? ""
            if firstLine.isEmpty { return call.input?.summary ?? call.name }
            return firstLine.count > 100 ? String(firstLine.prefix(100)) + "…" : firstLine
        } else {
            return call.input?.summary ?? call.name
        }
    }

    /// Strips markdown code fences from tool output for cleaner display
    private static func cleanOutput(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("```") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 10)

                    if hasRunningCalls {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .scaledFont(size: 11)
                            .foregroundColor(.green)
                    }

                    Text(headerLabel)
                        .scaledFont(size: 12, weight: .medium)

                    if !headerDetail.isEmpty {
                        Text(headerDetail)
                            .scaledFont(size: 11)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if hasRunningCalls {
                        ToolElapsedTime()
                            .scaledFont(size: 11)
                            .foregroundColor(.secondary)
                    }
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                if call.status == .running {
                                    ProgressView()
                                        .scaleEffect(0.4)
                                        .frame(width: 11, height: 11)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .scaledFont(size: 11)
                                        .foregroundColor(.green)
                                }
                                Text(call.name)
                                    .scaledFont(size: 12)
                                    .foregroundColor(.primary)
                                if let input = call.input {
                                    Text(input.summary)
                                        .scaledFont(size: 11)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                if call.status == .running {
                                    ToolElapsedTime()
                                        .scaledFont(size: 11)
                                        .foregroundColor(.secondary)
                                }
                            }
                            // Show tool output inline when available
                            if let output = call.output, !output.isEmpty {
                                let cleaned = ToolCallsGroup.cleanOutput(output)
                                if !cleaned.isEmpty {
                                    Text(cleaned)
                                        .scaledMonospacedFont(size: 11)
                                        .foregroundColor(.secondary)
                                        .lineLimit(6)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.primary.opacity(0.05))
                                        .cornerRadius(4)
                                        .padding(.leading, 17)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Shows elapsed time since the view appeared, updating every second
private struct ToolElapsedTime: View {
    @State private var startDate = Date()

    var body: some View {
        TimelineView(.periodic(from: startDate, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(startDate))
            if elapsed >= 5 {
                // Only show after 5 seconds to avoid flashing on quick tool calls
                Text(formatElapsed(elapsed))
            }
        }
    }

    private func formatElapsed(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else {
            let m = seconds / 60
            let s = seconds % 60
            return "\(m)m \(s)s"
        }
    }
}

// MARK: - Thinking Block View

struct ThinkingBlock: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .scaledFont(size: 10)
                    Image(systemName: "brain")
                        .scaledFont(size: 11)
                    Text("Thinking...")
                        .scaledFont(size: 12, weight: .medium)
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .scaledFont(size: 12)
                    .foregroundColor(.secondary)
                    .padding(.leading, 16)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Discovery Card View

struct DiscoveryCard: View {
    let title: String
    let summary: String
    let fullText: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 11)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(isExpanded ? fullText : summary)
                .scaledFont(size: 13)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - Observer Card View

struct ObserverCardView: View {
    let activityId: Int64
    let type: String
    let content: String
    let buttons: [ObserverCardButton]
    let actedAction: String?
    var onAction: ((Int64, String) -> Void)?

    @State private var selectedAction: String? = nil
    @State private var autoApproved: Bool = false
    @State private var expanded: Bool = false

    private var hasApproveButton: Bool {
        buttons.contains { $0.action == "approve" }
    }

    /// One-line summary: strip markdown, truncate
    private var oneLiner: String {
        let stripped = content
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "Saved: ", with: "")
            .replacingOccurrences(of: "Updated: ", with: "")
            .replacingOccurrences(of: "Confirmed: ", with: "")
        let firstLine = stripped.components(separatedBy: "\n").first ?? stripped
        return firstLine.count > 80 ? String(firstLine.prefix(77)) + "..." : firstLine
    }

    private var isDenied: Bool {
        selectedAction == "dismiss" && !autoApproved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact one-liner row
            HStack(spacing: 6) {
                Image(systemName: isDenied ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .scaledFont(size: 10)
                    .foregroundColor(isDenied ? Color.red.opacity(0.6) : Color.green.opacity(0.6))

                Text(oneLiner)
                    .scaledFont(size: 11, weight: .regular)
                    .foregroundColor(FazmColors.overlayForeground.opacity(isDenied ? 0.4 : 0.7))
                    .lineLimit(1)
                    .strikethrough(isDenied)

                Spacer()

                // Deny button inline
                if autoApproved && !isDenied {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedAction = "dismiss"
                            autoApproved = false
                        }
                        onAction?(activityId, "dismiss")
                    } label: {
                        Text("Deny")
                            .scaledFont(size: 10, weight: .medium)
                            .foregroundColor(FazmColors.overlayForeground.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }

                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .scaledFont(size: 9)
                    .foregroundColor(FazmColors.overlayForeground.opacity(0.3))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            }

            // Expanded detail
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    SelectableMarkdown(text: content, sender: .ai)
                        .fixedSize(horizontal: false, vertical: true)

                    if !buttons.isEmpty && selectedAction == nil {
                        HStack(spacing: 8) {
                            ForEach(buttons) { button in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedAction = button.action
                                    }
                                    onAction?(activityId, button.action)
                                } label: {
                                    Text(button.label)
                                        .scaledFont(size: 11, weight: .medium)
                                        .foregroundColor(FazmColors.overlayForeground.opacity(0.7))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                .background(FazmColors.overlayForeground.opacity(0.08))
                                .cornerRadius(5)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            if selectedAction == nil, let acted = actedAction {
                selectedAction = acted
                if acted == "approve" { autoApproved = true }
            } else if selectedAction == nil && hasApproveButton {
                selectedAction = "approve"
                autoApproved = true
                onAction?(activityId, "approve")
            }
        }
    }
}

// MARK: - Observer Card Stack

struct ObserverCardItem: Identifiable {
    let id: String
    let activityId: Int64
    let type: String
    let content: String
    let buttons: [ObserverCardButton]
    let actedAction: String?
}

struct ObserverCardStackView: View {
    let cards: [ObserverCardItem]
    var isChatObserverRunning: Bool = false
    var onAction: ((Int64, String) -> Void)?

    @State private var expanded: Bool = false
    @State private var pulseOpacity: Double = 0.7
    @Environment(\.fazmWindowIsVisible) private var windowIsVisible

    /// Only run the `repeatForever` pulse when the window is actually on screen.
    /// Otherwise SwiftUI keeps re-laying out every frame for occluded pop-outs,
    /// burning CPU. See `WindowVisibility.swift`.
    private var pulseAnimationActive: Bool { isChatObserverRunning && windowIsVisible }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — tap to expand/collapse
            HStack(spacing: 6) {
                Image(systemName: "eye.circle.fill")
                    .scaledFont(size: 11)
                    .foregroundColor(FazmColors.purplePrimary.opacity(pulseAnimationActive ? pulseOpacity : 0.7))
                    .animation(pulseAnimationActive ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default, value: pulseOpacity)
                    .onAppear {
                        pulseOpacity = pulseAnimationActive ? 0.3 : 0.7
                    }
                    .onChange(of: pulseAnimationActive) { _, active in
                        // Toggling between 0.3 and 0.7 with the new animation
                        // value snaps the in-flight repeatForever to a static
                        // value when the window goes occluded.
                        pulseOpacity = active ? 0.3 : 0.7
                    }

                if isChatObserverRunning && cards.isEmpty {
                    Text("Chat observer is thinking...")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundColor(FazmColors.overlayForeground.opacity(0.4))
                } else {
                    Text("Chat observer noted \(cards.count) thing\(cards.count == 1 ? "" : "s")")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundColor(FazmColors.overlayForeground.opacity(0.5))
                }

                Spacer()

                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .scaledFont(size: 9)
                    .foregroundColor(FazmColors.overlayForeground.opacity(0.3))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            }

            if expanded {
                Divider()
                    .background(FazmColors.purplePrimary.opacity(0.15))

                ForEach(cards) { card in
                    ObserverCardView(
                        activityId: card.activityId,
                        type: card.type,
                        content: card.content,
                        buttons: card.buttons,
                        actedAction: card.actedAction,
                        onAction: onAction
                    )

                    if card.id != cards.last?.id {
                        Divider()
                            .background(FazmColors.purplePrimary.opacity(0.1))
                            .padding(.horizontal, 10)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(FazmColors.purplePrimary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(FazmColors.purplePrimary.opacity(0.15), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animating = false
    @Environment(\.fazmWindowIsVisible) private var windowIsVisible

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .offset(y: animating ? -4 : 0)
                    .opacity(animating ? 1.0 : 0.4)
                    .animation(
                        windowIsVisible
                            ? .easeInOut(duration: 0.4)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.15)
                            : .default,
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = windowIsVisible
        }
        .onChange(of: windowIsVisible) { _, visible in
            // Restart from the steady state when the window becomes visible
            // again. When hidden, snap to the non-animated frame so SwiftUI
            // doesn't keep ticking the repeatForever loop on an offscreen view.
            animating = visible
        }
    }
}

// MARK: - MarkdownUI Theme Extensions

extension Theme {
    static func aiMessage() -> Theme {
        .gitHub.text {
            ForegroundColor(FazmColors.textPrimary)
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(13)
            BackgroundColor(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
        .link {
            ForegroundColor(FazmColors.purplePrimary)
        }
    }

    static func userMessage() -> Theme {
        .gitHub.text {
            ForegroundColor(.white)
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(13)
            BackgroundColor(Color.white.opacity(0.15))
        }
        .link {
            ForegroundColor(.white.opacity(0.9))
        }
    }
}
