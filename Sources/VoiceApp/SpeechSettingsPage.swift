import SwiftUI
import VoiceCore
import VoiceMLX
import VoicePlatform

struct SpeechSettingsPage: View {
    let model: VoiceAppModel

    var body: some View {
        VStack(spacing: VoiceVisualStyle.sectionSpacing) {
            DictationSettingsCard(model: model)
            SpokenResponseSettingsCard(model: model)
        }
    }
}

private struct DictationSettingsCard: View {
    @Bindable var model: VoiceAppModel

    private var dictationBackendBinding: Binding<VoiceAppModel.DictationBackend> {
        Binding(
            get: { model.selectedDictationBackend },
            set: { model.selectDictationBackend($0) }
        )
    }

    private var idleUnloadBinding: Binding<VoiceAppModel.MLXIdleUnloadDelay> {
        Binding(
            get: { model.mlxIdleUnloadDelay },
            set: { model.setMLXIdleUnloadDelay($0) }
        )
    }

    var body: some View {
        VoiceSectionCard(
            "Dictation",
            detail: "Choose the recognizer used while you hold Right Option.",
            systemImage: "waveform.badge.microphone"
        ) {
            Picker("Speech recognizer", selection: dictationBackendBinding) {
                ForEach(VoiceAppModel.DictationBackend.allCases) { backend in
                    Text(backend.rawValue).tag(backend)
                }
            }
            .disabled(
                model.isDictationModelPreparing
                    || model.isMLXBenchmarkActive
                    || ![.idle, .failed].contains(model.presentation.phase)
            )

            LabeledContent("Recognizer status") {
                if model.isDictationModelPreparing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(model.dictationModelStatus)
                    }
                } else {
                    Text(model.dictationModelStatus)
                }
            }

            if model.canCancelDictationModelPreparation {
                Button(
                    "Cancel model preparation",
                    role: .cancel,
                    action: model.cancelDictationModelPreparation
                )
            }

            if let error = model.dictationModelError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                if model.failedDictationBackend != nil {
                    Button("Retry model preparation", action: model.retryFailedDictationBackend)
                }
            }

            VoiceSupportingText(model.dictationBackendDescription)

            if let metrics = model.mlxMetricsDescription {
                Text(metrics)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            MLXBenchmarkRows(model: model)

            Divider()

            TextField(
                "Preferred spellings",
                text: $model.manualSpeechVocabularyText,
                prompt: Text("MLX, AVAudioEngine, project-specific names"),
                axis: .vertical
            )
            .lineLimit(2...4)
            .onSubmit(model.applyManualSpeechVocabulary)
            HStack(alignment: .firstTextBaseline) {
                Button(
                    "Apply preferred spellings",
                    action: model.applyManualSpeechVocabulary
                )
                Spacer()
                Text("Comma or newline separated · first 50")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VoiceSupportingText(
                "These explicit terms are prioritized ahead of the project-name vocabulary. "
                    + "Voice does not inspect focused-field contents or learn replacements "
                    + "from other applications."
            )

            Toggle(
                "Skip very short, near-silent MLX recordings",
                isOn: $model.skipSilentShortMLXAudio
            )
            VoiceSupportingText(
                "Off by default. When enabled, the conservative local signal gate rejects "
                    + "sub-four-second MLX captures only when peak, overall, and short-frame "
                    + "levels are all near silence."
            )

            Picker("Unload idle MLX dictation model", selection: idleUnloadBinding) {
                ForEach(VoiceAppModel.MLXIdleUnloadDelay.allCases) { delay in
                    Text(delay.label).tag(delay)
                }
            }
            VoiceSupportingText(
                "Keeps the current behavior by default. An unloaded model is restored locally "
                    + "on the next dictation; enabling this also starts releasing it when the "
                    + "Mac goes to sleep while Voice is idle."
            )

            Button(
                "Remove downloaded MLX models",
                role: .destructive,
                action: model.removeDownloadedMLXModels
            )
            .disabled(
                model.activeDictationBackend != .apple
                    || model.isDictationModelPreparing
                    || model.isMLXBenchmarkActive
                    || model.isMLXBenchmarkCacheRefreshing
            )
        }
    }
}

private struct SpokenResponseSettingsCard: View {
    @Bindable var model: VoiceAppModel

    private var voiceBinding: Binding<String?> {
        Binding(
            get: { model.selectedVoiceIdentifier },
            set: { model.selectVoice($0) }
        )
    }

    private var speechBackendBinding: Binding<VoiceAppModel.SpeechBackend> {
        Binding(
            get: { model.selectedSpeechBackend },
            set: { model.selectSpeechBackend($0) }
        )
    }

    var body: some View {
        VoiceSectionCard(
            "Spoken responses",
            detail: "System speech is the default; Qwen3-TTS remains fully local and opt in.",
            systemImage: "speaker.wave.2"
        ) {
            Picker("Speech engine", selection: speechBackendBinding) {
                ForEach(VoiceAppModel.SpeechBackend.allCases) { backend in
                    Text(backend.rawValue).tag(backend)
                }
            }
            .disabled(model.isSpeechModelPreparing)

            if model.selectedSpeechBackend == .system {
                Picker("Spoken voice", selection: voiceBinding) {
                    Text("Best installed English voice").tag(String?.none)
                    ForEach(AppleSpeechOutput.availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.language)")
                            .tag(String?.some(voice.identifier))
                    }
                }
                VoiceSupportingText(
                    "Voices installed in System Settings › Accessibility › Spoken Content "
                        + "appear here automatically."
                )
            } else {
                MLXVoiceControls(model: model)
            }

            LabeledContent("Engine status") {
                Text(model.speechModelStatus)
                    .foregroundStyle(model.speechModelError == nil ? .secondary : Color.red)
            }

            if let speechModelError = model.speechModelError {
                Text(speechModelError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct MLXVoiceControls: View {
    @Bindable var model: VoiceAppModel

    private var mlxSpeechVoiceBinding: Binding<MLXSpeechVoice> {
        Binding(
            get: { model.selectedMLXSpeechVoice },
            set: { model.selectMLXSpeechVoice($0) }
        )
    }

    private var mlxVoiceModeBinding: Binding<VoiceAppModel.MLXVoiceMode> {
        Binding(
            get: { model.mlxVoiceMode },
            set: { model.selectMLXVoiceMode($0) }
        )
    }

    var body: some View {
        Picker("Voice mode", selection: mlxVoiceModeBinding) {
            ForEach(VoiceAppModel.MLXVoiceMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }

        switch model.mlxVoiceMode {
        case .preset:
            Picker("MLX voice", selection: mlxSpeechVoiceBinding) {
                ForEach(MLXSpeechVoice.allCases) { voice in
                    Text(voice.displayName).tag(voice)
                }
            }
            TextField(
                "Speaking style (optional)",
                text: $model.mlxVoiceStyleText,
                prompt: Text("calm and unhurried")
            )
            .onSubmit(model.applyMLXVoiceSettings)
        case .designed:
            TextField(
                "Voice description",
                text: $model.mlxVoiceDescriptionText,
                prompt: Text("A warm, unhurried narrator with a South African accent"),
                axis: .vertical
            )
            .lineLimit(2...4)
            .onSubmit(model.applyMLXVoiceSettings)
            VoiceSupportingText(
                "Designed voices always use the 1.7B VoiceDesign model, regardless of "
                    + "the speech tier selected above."
            )
        case .cloned:
            LabeledContent("Reference clip") {
                Text(model.mlxCloneReferenceURL?.lastPathComponent ?? "Not selected")
                    .lineLimit(1)
            }
            Button("Choose Reference Clip…", action: model.chooseMLXCloneReferenceClip)
            TextField(
                "Words spoken in the clip",
                text: $model.mlxCloneTranscriptText,
                axis: .vertical
            )
            .lineLimit(1...3)
            .onSubmit(model.applyMLXVoiceSettings)
            TextField(
                "Accent or style (optional)",
                text: $model.mlxVoiceStyleText,
                prompt: Text("with a slight Korean accent")
            )
            .onSubmit(model.applyMLXVoiceSettings)
            VoiceSupportingText(
                "Use a clean 3–10 second clip of one speaker and enter its exact words. "
                    + "Adding a style re-conditions the clone for every response."
            )
        }

        VoiceSupportingText(
            "Press Return in a text field to apply it. Checkpoints are pinned and downloaded "
                + "from Hugging Face; spoken text and generated audio stay on this Mac."
        )
    }
}
