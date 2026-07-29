import SwiftUI

@main
struct VoiceApplication: App {
    @State private var model = VoiceAppModel()

    var body: some Scene {
        MenuBarExtra {
            VoiceMenuView(model: model)
        } label: {
            Label("Voice", systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Window("Voice Planning", id: "planning") {
            PlanningView(model: model)
                .frame(minWidth: 720, minHeight: 600)
                .background {
                    WindowTrackingView { window in
                        model.registerPlanningWindow(window)
                    }
                }
        }
        .defaultSize(width: 860, height: 720)

        Settings {
            SettingsView(model: model)
                .frame(width: 860, height: 700)
                .background {
                    WindowTrackingView { window in
                        model.registerSettingsWindow(window)
                    }
                }
        }
    }
}
