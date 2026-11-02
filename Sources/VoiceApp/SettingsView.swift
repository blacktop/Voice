import SwiftUI

struct SettingsView: View {
    @Bindable var model: VoiceAppModel
    @State private var selection: SettingsDestination? = .general

    var body: some View {
        NavigationSplitView {
            SettingsNavigation(selection: $selection)
                .navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 260)
        } detail: {
            SettingsDetail(selection: selection ?? .general, model: model)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case general
    case speech
    case planning
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .speech: "Speech"
        case .planning: "Planning"
        case .diagnostics: "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            "Permissions, hotkeys, insertion, and history"
        case .speech:
            "Recognition models and spoken responses"
        case .planning:
            "Project context and connected agents"
        case .diagnostics:
            "Inspect the last completed turn in memory"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "switch.2"
        case .speech: "waveform"
        case .planning: "sparkles"
        case .diagnostics: "stethoscope"
        }
    }

    var color: Color {
        switch self {
        case .general: .blue
        case .speech: .purple
        case .planning: .orange
        case .diagnostics: .teal
        }
    }
}

private struct SettingsNavigation: View {
    @Binding var selection: SettingsDestination?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VoiceAppIcon(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice")
                        .font(.headline)
                    Text("Private speech tools")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)

            List(SettingsDestination.allCases, selection: $selection) { destination in
                Label {
                    Text(destination.title)
                } icon: {
                    VoiceSymbolBadge(
                        systemImage: destination.systemImage, color: destination.color, size: 20)
                }
                .tag(destination)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Label("On-device by default", systemImage: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
        }
        .navigationTitle("Settings")
    }
}

private struct SettingsDetail: View {
    let selection: SettingsDestination
    let model: VoiceAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiceVisualStyle.sectionSpacing) {
                VoicePageHeader(
                    title: selection.title, subtitle: selection.subtitle,
                    systemImage: selection.systemImage, color: selection.color
                )
                .padding(.bottom, 8)
                Group {
                    switch selection {
                    case .general:
                        GeneralSettingsPage(model: model)
                    case .speech:
                        SpeechSettingsPage(model: model)
                    case .planning:
                        PlanningSettingsPage(model: model)
                    case .diagnostics:
                        DiagnosticsSettingsPage(model: model)
                    }
                }
            }
            .frame(maxWidth: VoiceVisualStyle.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(selection.title)
    }
}
