import AppKit
import SwiftUI

struct VoiceMenuView: View {
    @Bindable var model: VoiceAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading) {
            Label(
                model.isMLXBenchmarkActive
                    ? model.mlxBenchmarkStatus : model.menuStatusMessage,
                systemImage: model.menuBarSymbol
            )
            if !model.isHotkeyAvailable {
                Label(
                    "Open Settings to finish hotkey setup",
                    systemImage: "exclamationmark.triangle.fill")
            }
            Divider()
            if model.mlxBenchmarkPhase == .recording {
                Button(
                    "Stop and compare \(model.downloadedMLXBenchmarkModels.count) MLX models"
                ) {
                    model.stopAndRunMLXBenchmark()
                }
            }
            if model.isMLXBenchmarkActive {
                Button("Cancel MLX comparison", role: .cancel) {
                    model.cancelMLXBenchmark()
                }
                .disabled(model.mlxBenchmarkPhase == .cancelling)
                Divider()
            }
            Picker("Destination", selection: $model.destination) {
                ForEach(VoiceAppModel.CaptureDestination.allCases) { destination in
                    Text(destination.rawValue).tag(destination)
                }
            }
            .disabled(!model.isAgentConnected)

            Button("Open Planning…") {
                activateApp()
                openWindow(id: "planning")
                model.requestPlanningWindowReveal()
            }
            if model.isSpeakingPlanningResponse {
                Button("Stop Speaking", role: .cancel) {
                    model.stopSpeaking()
                }
                .help("Stop the spoken response without disconnecting the planning agent.")
                .accessibilityHint(
                    "Stops audio playback and keeps the planning agent connected."
                )
            }
            Button("Cancel current turn", role: .destructive) {
                model.cancel()
            }
            .disabled(
                model.isMLXBenchmarkActive || model.presentation.phase == .idle
            )
            Divider()
            Button("Settings…") {
                activateApp()
                openSettings()
                model.requestSettingsWindowReveal()
            }
            Button("Quit Voice") { model.quit() }
        }
    }

    /// Voice is a menu-bar utility (LSUIElement), so it is not the active
    /// application when a menu item is clicked; without activation, windows
    /// opened from the menu appear behind the frontmost app. Activation has to
    /// happen before the window is requested, because AppKit orders a new
    /// window into whichever app is frontmost at creation time.
    ///
    /// `NSApp.activate()` is the nominal replacement, but its cooperative model
    /// only activates an app the frontmost app has yielded to, which never
    /// happens for a status-item click; the window still opens behind. Re-check
    /// whether plain `activate()` raises the window on new macOS seeds before
    /// dropping `ignoringOtherApps`.
    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
