import SwiftUI
import VoiceNotifications

@main
struct VoiceApplication: App {
    @NSApplicationDelegateAdaptor(VoiceNotificationAppDelegate.self)
    private var notificationDelegate
    @State private var model: VoiceAppModel
    private let notificationDetailsWindow: NotificationDetailsWindowController

    init() {
        let model = VoiceAppModel()
        _model = State(initialValue: model)
        let window = NotificationDetailsWindowController { [model] text, voice, started in
            try await model.speakNotification(
                text, voice: voice, onPlaybackStarted: started)
        }
        notificationDetailsWindow = window
        notificationDelegate.setDetailsHandler { [window] details in window.show(details) }
    }

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
                .frame(minWidth: 800, minHeight: 600)
                .background {
                    WindowTrackingView { window in
                        model.registerSettingsWindow(window)
                    }
                }
        }
        .defaultSize(width: 860, height: 700)
    }
}
