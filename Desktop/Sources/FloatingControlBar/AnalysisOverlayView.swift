import SwiftUI

/// Overlay shown when Gemini session analysis detects a task the AI agent could help with.
struct AnalysisOverlayView: View {
    let task: String
    var onDiscuss: () -> Void
    var onHide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.purple)
                    .scaledFont(size: 13)
                Text("Task Detected")
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundColor(.white)
                Spacer(minLength: 4)
                Button {
                    onHide()
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(task)
                .scaledFont(size: 12)
                .foregroundColor(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)

            HStack(spacing: 8) {
                Button {
                    onDiscuss()
                } label: {
                    Text("Discuss")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.purple.opacity(0.8))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Button {
                    onHide()
                } label: {
                    Text("Hide")
                        .scaledFont(size: 12, weight: .medium)
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.purple.opacity(0.4), lineWidth: 1)
                )
        )
        .padding(8)
    }
}
