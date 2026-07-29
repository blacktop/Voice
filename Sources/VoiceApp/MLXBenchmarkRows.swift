import Foundation
import SwiftUI
import VoiceMLX

struct MLXBenchmarkRows: View {
    @Bindable var model: VoiceAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Same-audio comparison", systemImage: "waveform.badge.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Memory only")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(model.mlxBenchmarkStatus)
                .font(.caption)

            if !model.downloadedMLXBenchmarkModels.isEmpty {
                Text(
                    "Cached: "
                        + model.downloadedMLXBenchmarkModels
                        .map(\.displayName)
                        .joined(separator: ", ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            MLXBenchmarkControls(model: model)

            if let error = model.mlxBenchmarkError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ForEach(model.mlxBenchmarkResults) { result in
                Divider()
                MLXBenchmarkResultRow(result: result)
            }

            VoiceSupportingText(
                "Only downloaded models run, one at a time, without network access. "
                    + "Audio is discarded after the comparison. Granite, Cohere, and "
                    + "Parakeet finish their current decode before cancellation can unload them."
            )
        }
        .padding(14)
        .background(
            Color.accentColor.opacity(0.045),
            in: RoundedRectangle(
                cornerRadius: VoiceVisualStyle.compactCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: VoiceVisualStyle.compactCornerRadius,
                style: .continuous
            )
            .stroke(Color.accentColor.opacity(0.11), lineWidth: 1)
        }
        .onAppear(perform: model.refreshMLXBenchmarkModels)
    }
}

private struct MLXBenchmarkControls: View {
    let model: VoiceAppModel

    var body: some View {
        switch model.mlxBenchmarkPhase {
        case .idle, .finished:
            Button(
                model.mlxBenchmarkPhase == .finished
                    ? "Record another comparison" : "Record comparison",
                action: model.startMLXBenchmark
            )
            .disabled(!model.canStartMLXBenchmark)
        case .starting, .comparing:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel", role: .cancel, action: model.cancelMLXBenchmark)
            }
        case .recording:
            HStack {
                Button(
                    "Stop and compare \(model.downloadedMLXBenchmarkModels.count) models",
                    action: model.stopAndRunMLXBenchmark
                )
                .buttonStyle(.borderedProminent)
                Button("Cancel", role: .cancel, action: model.cancelMLXBenchmark)
            }
        case .cancelling:
            ProgressView()
                .controlSize(.small)
        }
    }
}

private struct MLXBenchmarkResultRow: View {
    let result: MLXBenchmarkResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.model.displayName)
                .font(.caption.weight(.semibold))
            if let transcript = result.transcript {
                Text(transcript)
                    .textSelection(.enabled)
            } else {
                Text(result.errorDescription ?? "Model produced no transcript.")
                    .foregroundStyle(.red)
            }
            if let inferenceDuration = result.inferenceDuration,
                let realTimeFactor = result.realTimeFactor,
                let peakMemoryGB = result.peakMemoryGB
            {
                Text(
                    String(
                        format: "%.2fs inference for %.1fs audio · %.2fx realtime · %.2f GB peak",
                        inferenceDuration,
                        result.audioDuration,
                        realTimeFactor,
                        peakMemoryGB
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
