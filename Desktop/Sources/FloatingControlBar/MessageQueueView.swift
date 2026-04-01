import SwiftUI

/// Stacked queue of pending messages anchored above the follow-up input field.
/// Each item shows the message text, a drag handle for reordering, a "send now"
/// button to interrupt the current query, and a delete button on hover.
struct MessageQueueView: View {
    @Binding var queue: [QueuedMessage]
    var onSendNow: ((QueuedMessage) -> Void)?
    var onDelete: ((QueuedMessage) -> Void)?
    var onClearAll: (() -> Void)?
    var onReorder: ((IndexSet, Int) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("\(queue.count) queued")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: { onClearAll?() }) {
                    Text("Clear all")
                        .scaledFont(size: 10)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            // Queue items
            ForEach(queue) { item in
                QueueItemRow(
                    item: item,
                    onSendNow: { onSendNow?(item) },
                    onDelete: { onDelete?(item) }
                )
            }
            .onMove { source, destination in
                onReorder?(source, destination)
            }
        }
        .background(FazmColors.overlayForeground.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(FazmColors.overlayForeground.opacity(0.1), lineWidth: 1)
        )
    }
}

/// A single row in the message queue.
private struct QueueItemRow: View {
    let item: QueuedMessage
    let onSendNow: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundColor(FazmColors.overlayForeground.opacity(0.3))
                .frame(width: 16)

            // Message text
            Text(item.text)
                .scaledFont(size: 12)
                .foregroundColor(FazmColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Delete button (on hover)
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(FazmColors.overlayForeground.opacity(0.4))
                        .frame(width: 18, height: 18)
                        .background(FazmColors.overlayForeground.opacity(0.1))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            // Send now button
            Button(action: onSendNow) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(FazmColors.purplePrimary)
            }
            .buttonStyle(.plain)
            .help("Send now (interrupts current)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isHovered ? FazmColors.overlayForeground.opacity(0.05) : Color.clear)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
}
