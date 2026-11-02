import AppKit
import SwiftUI

enum NotificationTextPaging {
    static let maximumPageBytes = 32 * 1024

    @concurrent
    static func prepare(_ text: String) async -> [String]? { split(text) }

    static func split(_ text: String) -> [String]? {
        let bytes = Array(text.utf8)
        var pages: [String] = []
        var start = 0
        while start < bytes.count {
            guard !Task.isCancelled else { return nil }
            var end = start + min(maximumPageBytes, bytes.count - start)
            if end < bytes.count {
                // Keep every UTF-8 scalar intact, preferring a nearby line end.
                while bytes[end] & 0xC0 == 0x80 { end -= 1 }
                let searchStart = start + maximumPageBytes / 2
                if let newline = bytes[searchStart..<end].lastIndex(of: 10) {
                    end = newline + 1
                }
            }
            pages.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = end
        }
        return pages.isEmpty ? [""] : pages
    }
}

/// Keep large messages in TextKit's scrollable document instead of asking
/// SwiftUI to measure one unbounded Text whenever the window changes.
struct NotificationTextView: NSViewRepresentable {
    let contentID: UUID
    let page: Int
    let text: String

    func makeNSView(context: Context) -> NotificationTextScrollView {
        NotificationTextScrollView()
    }

    func updateNSView(_ view: NotificationTextScrollView, context: Context) {
        view.show(text, id: contentID, page: page)
    }
}

@MainActor
final class NotificationTextScrollView: NSScrollView {
    let textView = NSTextView(usingTextLayoutManager: true)
    private var contentID: UUID?
    private var page = 0

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textLayoutManager?.limitsLayoutForSuspiciousContents = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .textColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        textView.defaultParagraphStyle = paragraph
        textView.textContainerInset = NSSize(width: 13, height: 18)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Full notification")
        documentView = textView
    }

    required init?(coder: NSCoder) { nil }

    func show(_ text: String, id: UUID, page: Int = 0) {
        guard contentID != id || self.page != page else { return }
        contentID = id
        self.page = page
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }
}
