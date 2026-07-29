import AppKit
import SwiftUI

enum VoiceVisualStyle {
    static let contentWidth: CGFloat = 760
    static let cornerRadius: CGFloat = 18
    static let compactCornerRadius: CGFloat = 13
    static let sectionSpacing: CGFloat = 18
}

struct VoiceAmbientBackground: View {
    let accent: Color

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [accent.opacity(0.12), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 520
            )
            LinearGradient(
                colors: [Color.white.opacity(0.025), .clear, Color.black.opacity(0.025)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

struct VoiceSectionCard<Content: View>: View {
    let title: String
    let detail: String?
    let systemImage: String
    private let content: Content

    init(
        _ title: String,
        detail: String? = nil,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    if let detail {
                        VoiceSupportingText(detail)
                    }
                }
            }

            Divider()
                .opacity(0.65)

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.78),
            in: RoundedRectangle(cornerRadius: VoiceVisualStyle.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: VoiceVisualStyle.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.075), lineWidth: 1)
        }
    }
}

struct VoiceStatusPill: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(
                .regular.tint(color.opacity(0.14)),
                in: .capsule
            )
    }
}

struct VoiceSupportingText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
