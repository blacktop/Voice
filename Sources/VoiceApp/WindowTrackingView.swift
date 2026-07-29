import AppKit
import SwiftUI

struct WindowTrackingView: NSViewRepresentable {
    let onWindowChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context _: Context) -> TrackingNSView {
        TrackingNSView(onWindowChange: onWindowChange)
    }

    func updateNSView(_ nsView: TrackingNSView, context _: Context) {
        nsView.onWindowChange = onWindowChange
        nsView.reportWindow()
    }
}

@MainActor
final class TrackingNSView: NSView {
    var onWindowChange: @MainActor (NSWindow?) -> Void

    init(onWindowChange: @escaping @MainActor (NSWindow?) -> Void) {
        self.onWindowChange = onWindowChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportWindow()
    }

    func reportWindow() {
        onWindowChange(window)
    }
}
