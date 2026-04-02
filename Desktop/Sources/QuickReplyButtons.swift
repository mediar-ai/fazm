import SwiftUI

// MARK: - Quick Reply Buttons (shared between onboarding, floating bar, etc.)

/// Displays a question label and wrapping quick-reply buttons.
/// Used by both OnboardingChatView and AIResponseView.
struct QuickReplyButtonsView: View {
    let question: String
    let options: [String]
    var isDisabled: Bool = false
    /// Optional highlight predicate (e.g. for "Grant" buttons in onboarding)
    var isHighlighted: ((String) -> Bool)? = nil
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !question.isEmpty {
                Text(question)
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(FazmColors.textSecondary.opacity(0.8))
            }

            WrappingHStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    let highlighted = isHighlighted?(option) ?? false
                    Button(action: {
                        onSelect(option)
                    }) {
                        Text(option)
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundColor(highlighted ? .white : FazmColors.purplePrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                highlighted
                                    ? FazmColors.purplePrimary
                                    : FazmColors.purplePrimary.opacity(0.1)
                            )
                            .cornerRadius(20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(FazmColors.purplePrimary.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                }
            }
        }
    }
}

// MARK: - WrappingHStack Layout

/// A layout that arranges subviews horizontally, wrapping to the next line when space runs out.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.enumerated().reduce(CGFloat.zero) { total, enumerated in
            let (index, row) = enumerated
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            return total + rowHeight + (index > 0 ? spacing : 0)
        }
        let width = proposal.width ?? .infinity
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            var x = bounds.minX
            for item in row {
                item.subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private struct LayoutItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutItem]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutItem]] = [[]]
        var currentRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let widthWithSpacing = currentRowWidth > 0 ? size.width + spacing : size.width

            if currentRowWidth + widthWithSpacing > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentRowWidth = 0
            }

            rows[rows.count - 1].append(LayoutItem(subview: subview, size: size))
            currentRowWidth += currentRowWidth > 0 ? size.width + spacing : size.width
        }

        return rows
    }
}
