import SwiftUI

struct DiagnosticsSettingsPage: View {
    let model: VoiceAppModel

    var body: some View {
        VStack(spacing: VoiceVisualStyle.sectionSpacing) {
            VoiceSectionCard(
                "Last completed turn",
                detail: "These values stay in memory and are replaced by the next completed turn.",
                systemImage: "text.magnifyingglass"
            ) {
                DiagnosticTextBlock(
                    title: "Raw ASR",
                    text: model.lastRawTranscript.isEmpty
                        ? "No completed turn yet." : model.lastRawTranscript
                )
                DiagnosticTextBlock(
                    title: "Sent to target",
                    text: model.lastCleanedTranscript.isEmpty
                        ? "Not available." : model.lastCleanedTranscript
                )
                LabeledContent("Cleanup") {
                    Text(model.lastCleanupSourceDescription)
                }

                HStack {
                    Button("Copy diagnostics", action: model.copyLastTurnDiagnostics)
                    Button(
                        "Clear",
                        role: .destructive,
                        action: model.clearLastTurnDiagnostics
                    )
                }
                .disabled(!model.hasLastTurnDiagnostics)
            }

            VoiceSectionCard(
                "Reading the result",
                detail: "Use the two strings to isolate which stage changed the text.",
                systemImage: "arrow.triangle.branch"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "Raw correct, sent wrong: inspect cleanup",
                        systemImage: "wand.and.stars"
                    )
                    Label(
                        "Both correct, destination wrong: inspect insertion",
                        systemImage: "text.cursor"
                    )
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DiagnosticTextBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                .textSelection(.enabled)
                .padding(12)
                .background(
                    Color.primary.opacity(0.035),
                    in: RoundedRectangle(
                        cornerRadius: VoiceVisualStyle.compactCornerRadius,
                        style: .continuous
                    )
                )
        }
    }
}
