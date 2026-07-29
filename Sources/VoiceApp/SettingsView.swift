import SwiftUI

struct SettingsView: View {
    @Bindable var model: VoiceAppModel
    @State private var selection: SettingsDestination = .general

    var body: some View {
        ZStack {
            VoiceAmbientBackground(accent: selection.tint)

            HStack(spacing: 0) {
                SettingsNavigation(selection: $selection)
                    .frame(width: 190)

                Divider()

                SettingsDetail(selection: selection, model: model)
                    .tint(selection.tint)
            }
        }
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

    var tint: Color {
        switch self {
        case .general: .cyan
        case .speech: .purple
        case .planning: .orange
        case .diagnostics: .blue
        }
    }
}

private struct SettingsNavigation: View {
    @Binding var selection: SettingsDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Voice")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("Private speech tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 22)

            GlassEffectContainer(spacing: 9) {
                VStack(spacing: 9) {
                    ForEach(SettingsDestination.allCases) { destination in
                        SettingsNavigationButton(
                            destination: destination,
                            isSelected: selection == destination
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) {
                                selection = destination
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            Label("On-device by default", systemImage: "lock.shield.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(18)
        }
        .background(Color.primary.opacity(0.018))
    }
}

private struct SettingsNavigationButton: View {
    let destination: SettingsDestination
    let isSelected: Bool
    let action: () -> Void

    private var glass: Glass {
        if isSelected {
            return .regular.tint(destination.tint.opacity(0.2)).interactive()
        }
        return .identity
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? destination.tint : .secondary)
                    .frame(width: 20)
                Text(destination.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .glassEffect(
            glass,
            in: .rect(cornerRadius: VoiceVisualStyle.compactCornerRadius)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsDetail: View {
    let selection: SettingsDestination
    let model: VoiceAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: selection.systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(selection.tint)
                    .frame(width: 34, height: 34)
                    .glassEffect(
                        .regular.tint(selection.tint.opacity(0.16)),
                        in: .rect(cornerRadius: 10)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.title)
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(selection.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            ScrollView {
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
                .frame(maxWidth: VoiceVisualStyle.contentWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
