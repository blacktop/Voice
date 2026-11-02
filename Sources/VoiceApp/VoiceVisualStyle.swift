import AppKit
import SwiftUI

enum VoiceVisualStyle {
    static let contentWidth: CGFloat = 760
    static let cornerRadius: CGFloat = 14
    static let compactCornerRadius: CGFloat = 8
    static let sectionSpacing: CGFloat = 20
}

struct VoiceAppIcon: View {
    let size: CGFloat
    private static let image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct VoiceSymbolBadge: View {
    let systemImage: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: .rect(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

struct VoicePageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VoiceSymbolBadge(systemImage: systemImage, color: color, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    VoiceSupportingText(detail)
                }
            }
            .padding(.horizontal, 4)

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }
}

struct VoiceStatusLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
        .font(.caption)
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
