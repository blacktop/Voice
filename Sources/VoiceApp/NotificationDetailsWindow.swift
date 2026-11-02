import AppKit
import SwiftUI
import VoiceNotifications

@MainActor
final class NotificationDetailsWindowController: NSWindowController, NSWindowDelegate {
    private let presentation: NotificationDetailsPresentation

    init(speak: @escaping NotificationDetailsPresentation.Speak) {
        presentation = NotificationDetailsPresentation(speak: speak)
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ details: NotificationDetails) {
        presentation.show(details)
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            panel.title = "Voice Notification"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.minSize = NSSize(width: 520, height: 360)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.delegate = self
            panel.contentViewController = NSHostingController(
                rootView: NotificationDetailsView(presentation: presentation))
            panel.center()
            window = panel
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) { presentation.close() }
}

private struct NotificationDetailsView: View {
    let presentation: NotificationDetailsPresentation

    var body: some View {
        if let details = presentation.details {
            VStack(alignment: .leading, spacing: 18) {
                NotificationMessageHeader(details: details, presentation: presentation)
                NotificationMessageText(contentID: presentation.contentID, text: details.text)
                    .id(presentation.contentID)
                if let error = presentation.destinationError ?? presentation.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)
            .safeAreaBar(edge: .bottom) {
                NotificationPlaybackControls(
                    presentation: presentation, text: details.text
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
            .frame(minWidth: 500, minHeight: 330)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private struct NotificationMessageHeader: View {
    let details: NotificationDetails
    let presentation: NotificationDetailsPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VoiceAppIcon(size: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("Voice")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: details.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !details.subtitle.isEmpty {
                    Text(verbatim: details.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if let destination = details.destination {
                NotificationDestinationButton(
                    destination: destination, presentation: presentation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotificationDestinationButton: View {
    let destination: NotificationDestination
    let presentation: NotificationDetailsPresentation

    private var title: String {
        switch destination {
        case .zed: "Open in Zed"
        case .terminal: "Go to Terminal"
        }
    }

    var body: some View {
        Button(action: presentation.goToDestination) {
            HStack(spacing: 6) {
                if presentation.isOpeningDestination {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.forward.app")
                }
                Text(title)
            }
        }
        .buttonStyle(.glass)
        .disabled(presentation.isOpeningDestination)
        .fixedSize()
        .help("Go to this notification's project or terminal pane")
    }
}

private struct NotificationMessageText: View {
    let contentID: UUID
    let text: String
    @State private var pages: [String] = []
    @State private var page = 0

    private var pageText: String? {
        guard pages.indices.contains(page) else { return nil }
        return pages[page]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pageText {
                NotificationTextView(contentID: contentID, page: page, text: pageText)
            } else {
                ProgressView("Opening message…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if pages.count > 1 {
                Divider()
                HStack(spacing: 12) {
                    Button("Previous page", systemImage: "chevron.left") {
                        page = max(0, page - 1)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(page == 0)
                    Text("Page \(page + 1) of \(pages.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Next page", systemImage: "chevron.right") {
                        page = min(pages.count - 1, page + 1)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(page + 1 == pages.count)
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: VoiceVisualStyle.cornerRadius)
        )
        .clipShape(RoundedRectangle(cornerRadius: VoiceVisualStyle.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: VoiceVisualStyle.cornerRadius)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .accessibilityLabel("Full notification")
        .task {
            guard let prepared = await NotificationTextPaging.prepare(text), !Task.isCancelled
            else {
                return
            }
            pages = prepared
        }
    }
}

private struct NotificationPlaybackControls: View {
    let presentation: NotificationDetailsPresentation
    let text: String

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 10) {
                NotificationPlaybackStatus(
                    phase: presentation.phase, voice: presentation.playbackVoice)
                Spacer(minLength: 8)

                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.glass)
                .help("Copy the full notification text")

                if presentation.isActive {
                    Button("Stop", systemImage: "stop.fill") { presentation.stop() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Speak", systemImage: "play.fill") {
                        presentation.startSpeaking()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)

                    Menu {
                        Button("Speak with Selected Voice", systemImage: "waveform") {
                            presentation.startSpeaking(using: .selected)
                        }
                        Button("Speak with macOS Voice", systemImage: "speaker.wave.2") {
                            presentation.startSpeaking(using: .system)
                        }
                        Button("Speak with Apple Speech", systemImage: "text.bubble") {
                            presentation.startSpeaking(using: .appleSpeech)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 16)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .accessibilityLabel("More playback options")
                    .help("Choose another voice")
                }
            }
            .controlSize(.large)
        }
    }
}

private struct NotificationPlaybackStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: NotificationReplayPhase
    let voice: NotificationReplayVoice

    private var title: String {
        switch phase {
        case .idle: "Ready to speak"
        case .preparing: "Preparing audio…"
        case .speaking: voice == .system ? "Reading with macOS…" : "Speaking…"
        }
    }

    private var detail: String {
        if phase == .idle { return "Read this message aloud" }
        return switch voice {
        case .system: "macOS default voice"
        case .appleSpeech: "Apple Speech voice"
        case .selected: "Voice selected in Settings"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if phase == .preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: phase == .speaking ? "waveform" : "speaker.wave.2")
                        .font(.body.weight(.medium))
                        .foregroundStyle(phase == .speaking ? Color.accentColor : .secondary)
                        .symbolEffect(
                            .variableColor, isActive: phase == .speaking && !reduceMotion)
                }
            }
            .frame(width: 30, height: 30)
            .background(Color.accentColor.opacity(0.08), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private func notificationPreview() -> NotificationDetailsPresentation {
    let presentation = NotificationDetailsPresentation { _, _, started in started() }
    presentation.show(
        NotificationDetails(
            title: "Build · Voice", subtitle: "All checks passed",
            text:
                "The build is ready. Open the project when you return, "
                + "or listen to this message now."
        ))
    return presentation
}

#Preview("Notification") {
    NotificationDetailsView(presentation: notificationPreview())
        .frame(width: 660, height: 410)
}

#Preview("Preparing audio") {
    NotificationPlaybackStatus(phase: .preparing, voice: .selected)
        .padding(20)
}
