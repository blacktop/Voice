import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var model: VoiceAppModel

    var body: some View {
        VStack(spacing: VoiceVisualStyle.sectionSpacing) {
            VoiceSectionCard(
                "Permissions",
                detail: "Voice needs all three permissions for capture and target-safe insertion.",
                systemImage: "checkmark.shield"
            ) {
                VStack(spacing: 10) {
                    PermissionStatusRow(
                        title: "Microphone",
                        granted: model.microphoneGranted
                    )
                    PermissionStatusRow(
                        title: "Accessibility",
                        granted: model.accessibilityGranted
                    )
                    PermissionStatusRow(
                        title: "Input Monitoring",
                        granted: model.inputMonitoringGranted
                    )
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Button("Request or Refresh", action: model.requestPermissions)
                        .buttonStyle(.glassProminent)
                    VoiceSupportingText(
                        "After changing Privacy & Security settings, return to Voice. "
                            + "If the event tap remains unavailable, quit and reopen the app."
                    )
                }

                Divider()

                LabeledContent("System audio input") {
                    Text(model.defaultAudioInputDetail)
                        .foregroundStyle(
                            model.defaultAudioInputIsBluetooth ? .orange : .secondary
                        )
                }
                if model.defaultAudioInputIsBluetooth {
                    Label(
                        "Bluetooth microphone audio can take longer to become ready or change "
                            + "quality when the headset switches profiles. Voice waits for real "
                            + "audio before showing Listening; choose another input in System "
                            + "Settings if capture remains unreliable.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                VoiceSupportingText(
                    "Voice follows the macOS default input and never changes it automatically."
                )
            }

            VoiceSectionCard(
                "Capture and insertion",
                detail: "One global hold gesture, with a compatibility insertion path.",
                systemImage: "keyboard"
            ) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    GridRow {
                        Text("Hotkeys")
                            .foregroundStyle(.secondary)
                        Text("Right Option · Shift then Right Option")
                    }
                    GridRow {
                        Text("Event tap")
                            .foregroundStyle(.secondary)
                        Text(model.eventTapDescription)
                            .foregroundStyle(model.isHotkeyAvailable ? .green : .red)
                    }
                    GridRow {
                        Text("Last hotkey")
                            .foregroundStyle(.secondary)
                        Text(model.hotkeyDetectionDescription)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VoiceSupportingText(
                    "Hold the Option key immediately to the right of the space bar until "
                        + "the overlay says Listening. Left Option is intentionally ignored. "
                        + "On first use, model preparation may ask you to hold the key again."
                )

                Divider()

                Toggle(
                    "Compatibility insertion for terminals and other apps",
                    isOn: $model.compatibilityInsertionEnabled
                )
                VoiceSupportingText(
                    "On by default. ChatGPT uses its native Paste command. "
                        + "Other apps try direct Accessibility insertion first; "
                        + "Rex, Safari, and Brave can fall back to a temporary local clipboard paste. "
                        + "Voice restores the previous clipboard unless you copy something else. "
                        + "Other apps use targeted Unicode events. Voice stops if focus changes "
                        + "and never pastes through the clipboard into a detected password field."
                )
            }

            VoiceSectionCard(
                "History",
                detail: "Local, encrypted, and disabled until you opt in.",
                systemImage: "lock.doc"
            ) {
                Toggle("Encrypted local history", isOn: $model.historyEnabled)
                VoiceSupportingText(
                    "Raw microphone audio is never retained. Session export is always explicit."
                )
            }
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let granted: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Label(
                granted ? "Granted" : "Required",
                systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
            .foregroundStyle(granted ? .green : .orange)
        }
        .accessibilityElement(children: .combine)
    }
}
