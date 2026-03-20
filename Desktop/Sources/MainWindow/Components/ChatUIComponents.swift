import SwiftUI
import MarkdownUI

// MARK: - Content Block Grouping

/// Groups consecutive content blocks of the same type for rendering
enum ContentBlockGroup: Identifiable {
    case text(id: String, text: String)
    case toolCalls(id: String, calls: [(name: String, status: ToolCallStatus, toolUseId: String?, input: ToolCallInput?, output: String?)])
    case thinking(id: String, text: String)
    case discoveryCard(id: String, title: String, summary: String, fullText: String)
    case observerCard(id: String, activityId: Int64, type: String, content: String, buttons: [ObserverCardButton], actedAction: String? = nil)

    var id: String {
        switch self {
        case .text(let id, _): return id
        case .toolCalls(let id, _): return id
        case .thinking(let id, _): return id
        case .discoveryCard(let id, _, _, _): return id
        case .observerCard(let id, _, _, _, _, _): return id
        }
    }

    /// Groups consecutive content blocks into display groups
    static func group(_ blocks: [ChatContentBlock]) -> [ContentBlockGroup] {
        var result: [ContentBlockGroup] = []
        var pendingText = ""
        var pendingTextId = ""
        var pendingToolCalls: [(name: String, status: ToolCallStatus, toolUseId: String?, input: ToolCallInput?, output: String?)] = []
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
                flushToolCalls()
                if pendingText.isEmpty {
                    pendingTextId = id
                }
                pendingText += (pendingText.isEmpty ? "" : "\n\n") + text

            case .toolCall(let id, let name, let status, let toolUseId, let input, let output):
                flushText()
                if pendingToolCalls.isEmpty {
                    pendingToolCallsId = id
                }
                pendingToolCalls.append((name: name, status: status, toolUseId: toolUseId, input: input, output: output))

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
    let calls: [(name: String, status: ToolCallStatus, toolUseId: String?, input: ToolCallInput?, output: String?)]
    @State private var isExpanded = false

    /// The currently running call, or the last call if all completed
    private var latestCall: (name: String, status: ToolCallStatus, toolUseId: String?, input: ToolCallInput?, output: String?)? {
        calls.last(where: { $0.status == .running }) ?? calls.last
    }

    private var hasRunningCalls: Bool {
        calls.contains(where: { $0.status == .running })
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

                    Text("\(calls.count) tool \(calls.count == 1 ? "call" : "calls")")
                        .scaledFont(size: 12, weight: .medium)

                    Text(inlineSummary)
                        .scaledFont(size: 11)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

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
                                        .font(.system(size: 11, design: .monospaced))
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
    /// Pre-populated when the card was already acted on (persisted in DB)
    let actedAction: String?
    var onAction: ((Int64, String) -> Void)?

    @State private var selectedAction: String? = nil
    @State private var countdown: Int = 5
    @State private var countdownTimer: Timer? = nil

    /// Whether this card has an approve button and should auto-approve
    private var hasApproveButton: Bool {
        buttons.contains { $0.action == "approve" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Content
            SelectableMarkdown(text: content, sender: .ai)
                .fixedSize(horizontal: false, vertical: true)

            // Buttons
            if !buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(buttons) { button in
                        Button {
                            guard selectedAction == nil else { return }
                            countdownTimer?.invalidate()
                            countdownTimer = nil
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedAction = button.action
                            }
                            onAction?(activityId, button.action)
                        } label: {
                            HStack(spacing: 4) {
                                if selectedAction == button.action {
                                    Image(systemName: button.action == "dismiss" ? "xmark" : "checkmark")
                                        .scaledFont(size: 10, weight: .bold)
                                }
                                if button.action == "approve" && selectedAction == nil && hasApproveButton {
                                    Text("\(button.label) (\(countdown))")
                                        .scaledFont(size: 12, weight: .medium)
                                } else {
                                    Text(selectedAction == button.action ? buttonConfirmLabel(for: button.action) : button.label)
                                        .scaledFont(size: 12, weight: .medium)
                                }
                            }
                            .foregroundColor(buttonForeground(for: button.action))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .background(buttonBackgroundResolved(for: button.action))
                        .cornerRadius(6)
                        .opacity(selectedAction != nil && selectedAction != button.action ? 0.3 : 1.0)
                        .disabled(selectedAction != nil)
                    }
                }
            }
        }
        .padding(10)
        .onAppear {
            if selectedAction == nil, let acted = actedAction {
                selectedAction = acted
            } else if selectedAction == nil && hasApproveButton {
                startCountdown()
            }
        }
        .onDisappear {
            countdownTimer?.invalidate()
            countdownTimer = nil
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(FazmColors.purplePrimary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(FazmColors.purplePrimary.opacity(0.2), lineWidth: 1)
                )
        )
    }

    private func buttonConfirmLabel(for action: String) -> String {
        switch action {
        case "approve": return "Saved"
        case "dismiss": return "Dismissed"
        default: return action.capitalized
        }
    }

    private func buttonForeground(for action: String) -> Color {
        if let selected = selectedAction, action == selected {
            switch action {
            case "approve": return .green
            case "dismiss": return Color.red.opacity(0.9)
            default: return .white
            }
        }
        return .white
    }

    private func startCountdown() {
        countdown = 5
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            DispatchQueue.main.async {
                if countdown <= 1 {
                    timer.invalidate()
                    countdownTimer = nil
                    guard selectedAction == nil else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedAction = "approve"
                    }
                    onAction?(activityId, "approve")
                } else {
                    countdown -= 1
                }
            }
        }
    }

    private func buttonBackgroundResolved(for action: String) -> Color {
        if let selected = selectedAction {
            if action == selected {
                switch action {
                case "approve": return Color.green.opacity(0.2)
                case "dismiss": return Color.red.opacity(0.15)
                default: return Color.white.opacity(0.2)
                }
            } else {
                return Color.white.opacity(0.04)
            }
        }
        // Default (before any click)
        switch action {
        case "approve": return Color.green.opacity(0.15)
        case "dismiss": return Color.white.opacity(0.08)
        default: return Color.white.opacity(0.1)
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .offset(y: animating ? -4 : 0)
                    .opacity(animating ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear {
            animating = true
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
