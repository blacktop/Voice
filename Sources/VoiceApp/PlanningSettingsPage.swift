import SwiftUI

struct PlanningSettingsPage: View {
    @Bindable var model: VoiceAppModel

    private var projectButtonHelp: String {
        if model.isProjectSelectionLocked {
            return VoiceAppModel.projectSelectionLockedHelp
        }
        return "Choose the project used for vocabulary and planning."
    }

    var body: some View {
        VStack(spacing: VoiceVisualStyle.sectionSpacing) {
            VoiceSectionCard(
                "Project context",
                detail: "One folder supplies filename terms and the connected agent "
                    + "working directory.",
                systemImage: "folder"
            ) {
                LabeledContent("Project") {
                    Text(model.projectURL?.path(percentEncoded: false) ?? "Not selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("Context terms") {
                    Text("\(model.lexiconCount)")
                }
                Button(
                    model.projectURL == nil ? "Choose Project…" : "Choose Another Project…",
                    action: model.chooseProject
                )
                .buttonStyle(.glass)
                .disabled(model.isProjectSelectionLocked)
                .help(projectButtonHelp)
                .accessibilityHint(projectButtonHelp)
            }

            PlanningBackendCard(model: model)

            if !model.agentConfigurationOptions.isEmpty {
                AgentConfigurationControls(model: model)
            }

            VoiceSectionCard(
                "Trust boundary",
                detail: "The selected backend determines where finalized planning text goes.",
                systemImage: "lock.shield"
            ) {
                Text(model.planningPrivacyDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PlanningBackendCard: View {
    @Bindable var model: VoiceAppModel

    private var acpAgentBinding: Binding<String> {
        Binding(
            get: { model.acpAgentSelectionID },
            set: { model.selectACPAgent($0) }
        )
    }

    var body: some View {
        VoiceSectionCard(
            "Planning backend",
            detail: "Connect from the Planning window after choosing the backend here.",
            systemImage: "point.3.connected.trianglepath.dotted"
        ) {
            Picker("Backend", selection: $model.planningBackend) {
                ForEach(VoiceAppModel.PlanningBackend.allCases) { backend in
                    Text(backend.rawValue).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isProjectSelectionLocked)

            switch model.planningBackend {
            case .onDevice:
                LabeledContent("Model") {
                    Text("SystemLanguageModel")
                }
            case .codex:
                LabeledContent("Codex") {
                    Text(model.codexExecutableURL.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("Choose Codex Executable…", action: model.chooseCodexExecutable)
            case .acp:
                ACPBackendControls(
                    model: model,
                    acpAgentBinding: acpAgentBinding,
                    isLocked: model.isProjectSelectionLocked
                )
            }
        }
    }
}

private struct ACPBackendControls: View {
    @Bindable var model: VoiceAppModel
    let acpAgentBinding: Binding<String>
    let isLocked: Bool

    var body: some View {
        if !model.discoveredACPAgents.isEmpty {
            Picker("Zed agent", selection: acpAgentBinding) {
                ForEach(model.discoveredACPAgents) { choice in
                    Text(choice.displayName).tag(choice.id)
                }
                if model.acpAgentSelectionID == VoiceAppModel.customACPAgentSelectionID {
                    Text("Custom executable").tag(VoiceAppModel.customACPAgentSelectionID)
                }
            }
            .disabled(isLocked)
        }

        LabeledContent("ACP agent") {
            Text(model.acpExecutableURL?.path(percentEncoded: false) ?? "Not selected")
                .lineLimit(1)
                .truncationMode(.middle)
        }

        HStack {
            Button("Choose ACP Executable…", action: model.chooseACPExecutable)
                .disabled(isLocked)
            Button("Refresh Zed Agents", action: model.refreshACPAgents)
                .disabled(model.isDiscoveringACPAgents || isLocked)
            if model.isDiscoveringACPAgents {
                ProgressView()
                    .controlSize(.small)
            }
        }

        LabeledContent("Arguments") {
            TextField(
                "One argument per line",
                text: $model.acpArgumentsText,
                axis: .vertical
            )
            .lineLimit(2...4)
            .disabled(isLocked)
        }

        VoiceSupportingText(
            "Voice detects Claude and Codex ACP launchers installed by Zed. Manual "
                + "executable and one-argument-per-line fields remain available."
        )

        if model.agentConfigurationOptions.isEmpty {
            VoiceSupportingText(
                "Connect the ACP agent to load its model, effort, mode, and other controls."
            )
        }
    }
}
