import SwiftUI

/// Overlay shown when PTT finishes with no speech detected.
/// Displays a mic picker and live audio level so the user can verify their mic works.
struct SilenceOverlayView: View {
    @ObservedObject private var deviceManager = AudioDeviceManager.shared
    var onDismiss: () -> Void

    private var selectedDeviceName: String {
        if let uid = deviceManager.selectedDeviceUID,
           let device = deviceManager.devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return "System Default"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "mic.slash.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 13))
                Text("Didn't catch that — try a different mic?")
                    .scaledFont(size: 12, weight: .medium)
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }

            // Mic picker — SwiftUI Button that shows a native NSMenu on click
            Button {
                showMicMenu()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10))
                    Text(selectedDeviceName)
                        .scaledFont(size: 12)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.5))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            AudioLevelBarsSettingsView(level: deviceManager.currentAudioLevel)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
                )
        )
        .padding(8)
        .onAppear { deviceManager.startLevelMonitoring() }
        .onDisappear { deviceManager.stopLevelMonitoring() }
    }

    private func showMicMenu() {
        let menu = NSMenu()

        let defaultItem = NSMenuItem(title: "System Default", action: #selector(MicMenuTarget.selectDevice(_:)), keyEquivalent: "")
        defaultItem.target = MicMenuTarget.shared
        defaultItem.representedObject = nil as String?
        if deviceManager.selectedDeviceUID == nil {
            defaultItem.state = .on
        }
        menu.addItem(defaultItem)

        menu.addItem(NSMenuItem.separator())

        for device in deviceManager.devices {
            let item = NSMenuItem(title: device.name, action: #selector(MicMenuTarget.selectDevice(_:)), keyEquivalent: "")
            item.target = MicMenuTarget.shared
            item.representedObject = device.uid
            if deviceManager.selectedDeviceUID == device.uid {
                item.state = .on
            }
            menu.addItem(item)
        }

        // Show at mouse location
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Target for NSMenu item actions (must be NSObject for @objc selectors).
private class MicMenuTarget: NSObject {
    static let shared = MicMenuTarget()

    @objc func selectDevice(_ sender: NSMenuItem) {
        Task { @MainActor in
            let uid = sender.representedObject as? String
            AudioDeviceManager.shared.selectedDeviceUID = uid
        }
    }
}
