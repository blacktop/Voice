import AppKit
import SwiftUI
import VoiceCore

@MainActor
final class StatusPanelController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func update(
        with presentation: VoicePresentation,
        onDevicePlanning: Bool
    ) {
        hideTask?.cancel()
        if panel == nil {
            panel = makePanel()
        }
        guard let panel,
            let hosting = panel.contentViewController as? NSHostingController<StatusOverlayView>
        else { return }
        hosting.rootView = StatusOverlayView(
            presentation: presentation,
            onDevicePlanning: onDevicePlanning
        )

        if presentation.phase == .idle {
            scheduleHide(panel, after: .milliseconds(900))
            return
        }
        position(panel)
        panel.orderFrontRegardless()
        if presentation.phase == .failed {
            scheduleHide(panel, after: .seconds(5))
        }
    }

    private func makePanel() -> NSPanel {
        let size = StatusOverlayView.preferredSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(
            rootView: StatusOverlayView(
                presentation: .idle,
                onDevicePlanning: true
            )
        )
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.setContentSize(size)
        return panel
    }

    private func scheduleHide(_ panel: NSPanel, after delay: Duration) {
        hideTask = Task { @MainActor [weak panel] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - panel.frame.height - 54
            )
        )
    }
}

struct StatusOverlayView: View {
    static let preferredSize = CGSize(width: 460, height: 104)

    let presentation: VoicePresentation
    let onDevicePlanning: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .symbolEffect(.pulse, isActive: presentation.phase == .listening)
                .foregroundStyle(accent)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Text(boundaryLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(
                            boundaryColor
                        )
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .padding(8)
        .frame(
            width: Self.preferredSize.width,
            height: Self.preferredSize.height
        )
    }

    private var title: String {
        switch presentation.phase {
        case .listening: "Listening"
        case .finalizing: "Finalizing"
        case .cleaning: "Cleaning on-device"
        case .inserting: "Inserting"
        case .planning: "Planning"
        case .speaking: "Speaking"
        case .failed: "Voice needs attention"
        default: "Voice"
        }
    }

    private var boundaryLabel: String {
        guard presentation.isConnectedPlanning else { return "LOCAL" }
        return onDevicePlanning ? "ON-DEVICE" : "FINAL TEXT OUT"
    }

    private var boundaryColor: Color {
        presentation.isConnectedPlanning && !onDevicePlanning ? .orange : .green
    }

    private var detail: String {
        if presentation.phase == .planning || presentation.phase == .speaking,
            !presentation.message.isEmpty
        {
            return presentation.message
        }
        if !presentation.transcript.isEmpty {
            return presentation.transcript
        }
        return presentation.message
    }

    private var symbol: String {
        switch presentation.phase {
        case .listening: "waveform"
        case .speaking: "speaker.wave.2.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "sparkles"
        }
    }

    private var accent: Color {
        presentation.phase == .failed ? .red : .accentColor
    }
}
