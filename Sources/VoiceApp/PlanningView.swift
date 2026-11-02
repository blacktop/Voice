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
        ScrollView {
            VStack(alignment: .leading, spacing: VoiceVisualStyle.sectionSpacing) {
                PlanningHeader(
                    status: connectionStatus,
                    statusSymbol: connectionSymbol,
                    statusColor: connectionColor
                )

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
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaBar(edge: .bottom) {
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
        VStack(alignment: .leading, spacing: 10) {
            VoicePageHeader(
                title: "Planning",
                subtitle: "Speak a problem through, keep the full response in view.",
                systemImage: "sparkles", color: .orange)
            VoiceStatusLabel(
                title: status,
                systemImage: statusSymbol,
                color: statusColor
            )
            .padding(.leading, 58)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
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
