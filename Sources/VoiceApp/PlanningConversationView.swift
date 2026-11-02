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
                text: transcript.isEmpty ? "Hold Right Option to talk." : transcript,
                isPlaceholder: transcript.isEmpty,
                minimumHeight: 76
            )

            PlanningMessageSurface(
                title: phase == .speaking ? "Agent · speaking" : "Agent",
                systemImage: phase == .speaking ? "speaker.wave.2.fill" : "sparkles",
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
    let text: String
    let isPlaceholder: Bool
    let minimumHeight: CGFloat

    var body: some View {
        VoiceSectionCard(title, systemImage: systemImage) {
            Text(text)
                .font(.body)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .topLeading)
                .textSelection(.enabled)
        }
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
            .controlSize(.regular)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}
