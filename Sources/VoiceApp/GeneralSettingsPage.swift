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
                HStack(spacing: 10) {
                    PermissionStatusTile(
                        title: "Microphone",
                        granted: model.microphoneGranted
                    )
                    PermissionStatusTile(
                        title: "Accessibility",
                        granted: model.accessibilityGranted
                    )
                    PermissionStatusTile(
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
                    "Compatibility Unicode insertion for Zed and other apps",
                    isOn: $model.compatibilityInsertionEnabled
                )
                VoiceSupportingText(
                    "On by default. Voice only falls back to PID-targeted Unicode events "
                        + "when direct AX insertion is rejected, as it is by Zed terminals, "
                        + "cmux, and Ghostty; apps that accept AX insertion are unaffected. "
                        + "Voice still aborts if focus changes. Turn this off to require "
                        + "direct AX insertion everywhere."
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

private struct PermissionStatusTile: View {
    let title: String
    let granted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(granted ? "Granted" : "Required")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (granted ? Color.green : Color.orange).opacity(0.055),
            in: RoundedRectangle(
                cornerRadius: VoiceVisualStyle.compactCornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .combine)
    }
}
