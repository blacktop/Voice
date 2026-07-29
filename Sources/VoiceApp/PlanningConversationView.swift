import SwiftUI
import VoiceCore

struct PlanningConversationView: View {
    let transcript: String
    let agentMessage: String?
    let phase: VoiceSessionPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PlanningMessageSurface(
                title: "You said",
                systemImage: "waveform",
                accent: .blue,
                text: transcript.isEmpty ? "Hold Right Option to talk." : transcript,
                isPlaceholder: transcript.isEmpty,
                minimumHeight: 76
            )

            PlanningMessageSurface(
                title: phase == .speaking ? "Agent · speaking" : "Agent",
                systemImage: phase == .speaking ? "speaker.wave.2.fill" : "sparkles",
                accent: .purple,
                text: agentMessage
                    ?? "Connect a planning model, then hold Right Option to talk.",
                isPlaceholder: agentMessage == nil,
                minimumHeight: 230
            )
        }
    }
}

private struct PlanningMessageSurface: View {
    let title: String
    let systemImage: String
    let accent: Color
    let text: String
    let isPlaceholder: Bool
    let minimumHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(accent)

            Text(text)
                .font(.body)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
                .textSelection(.enabled)
        }
        .padding(18)
        .background(
            accent.opacity(0.045),
            in: RoundedRectangle(cornerRadius: VoiceVisualStyle.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: VoiceVisualStyle.cornerRadius, style: .continuous)
                .stroke(accent.opacity(0.16), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.2), value: title)
    }
}

struct PlanningActionDock: View {
    let connectTitle: String
    let isConnected: Bool
    let isConnecting: Bool
    let canExport: Bool
    let isSpeaking: Bool
    let connect: () -> Void
    let export: () -> Void
    let stopSpeaking: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                Button(action: connect) {
                    Label(
                        connectTitle,
                        systemImage: isConnected ? "bolt.slash.fill" : "bolt.fill"
                    )
                }
                .buttonStyle(.glassProminent)
                .disabled(isConnecting)

                Button(action: export) {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
                .disabled(!canExport)

                if isSpeaking {
                    Button(role: .cancel, action: stopSpeaking) {
                        Label("Stop Speaking", systemImage: "stop.fill")
                    }
                    .buttonStyle(.glass)
                    .tint(.red)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help(
                        "Stop the spoken response without disconnecting the planning agent."
                    )
                    .accessibilityHint(
                        "Stops audio playback and keeps the planning agent connected."
                    )
                }

                Spacer()

                Label("Right Option · Shift for Polish", systemImage: "keyboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .glassEffect(
                .regular,
                in: .rect(cornerRadius: VoiceVisualStyle.cornerRadius)
            )
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }
}
