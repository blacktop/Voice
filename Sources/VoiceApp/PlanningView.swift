import Foundation
import SwiftUI

struct PlanningView: View {
    @Bindable var model: VoiceAppModel

    private var agentMessage: String? {
        guard model.presentation.isConnectedPlanning,
            !model.presentation.message.isEmpty
        else { return nil }
        return model.presentation.message
    }

    private var connectButtonTitle: String {
        if model.isAgentConnecting {
            return "Connecting…"
        }
        return model.isAgentConnected ? "Disconnect" : "Connect \(model.planningBackendLabel)"
    }

    private var connectionStatus: String {
        if model.isAgentConnecting {
            return "Connecting · \(model.planningBackendLabel)"
        }
        return model.isAgentConnected
            ? "Connected · \(model.planningBackendLabel)"
            : "No planning model connected"
    }

    private var connectionColor: Color {
        guard model.isAgentConnected || model.isAgentConnecting else { return .secondary }
        return model.planningBackend == .onDevice ? .green : .orange
    }

    private var connectionSymbol: String {
        if model.isAgentConnecting {
            return "ellipsis"
        }
        return model.isAgentConnected ? "checkmark.circle.fill" : "circle.dashed"
    }

    var body: some View {
        ZStack {
            VoiceAmbientBackground(accent: connectionColor)

            VStack(spacing: 0) {
                PlanningHeader(
                    status: connectionStatus,
                    statusSymbol: connectionSymbol,
                    statusColor: connectionColor
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: VoiceVisualStyle.sectionSpacing) {
                        PlanningProjectCard(model: model)

                        if !model.agentConfigurationOptions.isEmpty {
                            AgentConfigurationControls(model: model)
                        }

                        PlanningConversationView(
                            transcript: model.presentation.transcript,
                            agentMessage: agentMessage,
                            phase: model.presentation.phase
                        )
                    }
                    .frame(maxWidth: VoiceVisualStyle.contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }

                PlanningActionDock(
                    connectTitle: connectButtonTitle,
                    isConnected: model.isAgentConnected,
                    isConnecting: model.isAgentConnecting,
                    canExport: !model.lastExportableText.isEmpty,
                    isSpeaking: model.isSpeakingPlanningResponse,
                    connect: toggleConnection,
                    export: model.exportLastSession,
                    stopSpeaking: model.stopSpeaking
                )
            }
        }
    }

    private func toggleConnection() {
        if model.isAgentConnected {
            model.disconnectPlanning()
        } else {
            model.connectPlanning()
        }
    }
}

private struct PlanningHeader: View {
    let status: String
    let statusSymbol: String
    let statusColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice Planning")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text("Speak a problem through, keep the full response in view.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            VoiceStatusPill(
                title: status,
                systemImage: statusSymbol,
                color: statusColor
            )
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }
}

private struct PlanningProjectCard: View {
    let model: VoiceAppModel

    private var projectButtonTitle: String {
        model.projectURL == nil ? "Choose Project…" : "Choose Another Project…"
    }

    private var projectButtonHelp: String {
        if model.isProjectSelectionLocked {
            return VoiceAppModel.projectSelectionLockedHelp
        }
        return projectButtonTitle
    }

    var body: some View {
        VoiceSectionCard(
            "Planning project",
            detail: "Sets the agent working directory and the filename-only speech vocabulary.",
            systemImage: "folder"
        ) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(projectName)
                        .font(.headline)
                        .foregroundStyle(model.projectURL == nil ? .secondary : .primary)
                    Text(projectPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(projectPath)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(projectButtonTitle, action: model.chooseProject)
                    .buttonStyle(.glass)
                    .disabled(model.isProjectSelectionLocked)
                    .help(projectButtonHelp)
                    .accessibilityHint(projectButtonHelp)
            }
        }
    }

    private var projectName: String {
        guard let projectURL = model.projectURL else { return "No project selected" }
        if projectURL.lastPathComponent.isEmpty {
            return projectURL.path(percentEncoded: false)
        }
        return projectURL.lastPathComponent
    }

    private var projectPath: String {
        model.projectURL?.path(percentEncoded: false)
            ?? "Choose a project before starting a planning session."
    }
}
