import SwiftUI
import VoiceCore

struct AgentConfigurationControls: View {
    let model: VoiceAppModel

    private let columns = [
        GridItem(.adaptive(minimum: 190), spacing: 12, alignment: .top)
    ]

    var body: some View {
        VoiceSectionCard(
            "Agent configuration",
            detail: "Controls are advertised by the connected ACP agent.",
            systemImage: "slider.horizontal.3"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(model.agentConfigurationOptions) { option in
                        AgentConfigurationControl(model: model, option: option)
                    }
                }
                if model.isAgentConfigurationUpdating {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Applying agent configuration…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = model.agentConfigurationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

private struct AgentConfigurationControl: View {
    let model: VoiceAppModel
    let option: AgentSessionConfigurationOption

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch option.currentValue {
            case .boolean(let enabled):
                Toggle(option.name, isOn: booleanBinding(enabled))
            case .string(let selected):
                Picker(option.name, selection: stringBinding(selected)) {
                    ForEach(option.displayChoices) { choice in
                        Text(choice.name)
                            .tag(choice.value)
                            .help(choice.description ?? choice.name)
                    }
                }
                .pickerStyle(.menu)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .disabled(model.isAgentConfigurationUpdating || !model.isAgentConnected)
    }

    private var detail: String? {
        if case .string(let selected) = option.currentValue,
            let choiceDescription = option.displayChoices
                .first(where: { $0.value == selected })?.description
        {
            return choiceDescription
        }
        return option.description
    }

    private func booleanBinding(_ currentValue: Bool) -> Binding<Bool> {
        Binding(
            get: { currentValue },
            set: { value in
                model.selectAgentConfiguration(
                    optionID: option.id,
                    value: .boolean(value)
                )
            }
        )
    }

    private func stringBinding(_ currentValue: String) -> Binding<String> {
        Binding(
            get: { currentValue },
            set: { value in
                model.selectAgentConfiguration(
                    optionID: option.id,
                    value: .string(value)
                )
            }
        )
    }
}
