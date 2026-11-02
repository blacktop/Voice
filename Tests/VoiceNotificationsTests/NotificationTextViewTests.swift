import AppKit
import CryptoKit
import XCTest

@MainActor
final class NotificationTextViewTests: XCTestCase {
    func testLargeMessageCanBeReplacedWithoutLosingText() throws {
        let view = NotificationTextScrollView()
        let line = "Synthetic notification text.\n"
        let byteCount = 8 * 1024 * 1024
        let text =
            String(repeating: line, count: byteCount / line.utf8.count)
            + String(repeating: ".", count: byteCount % line.utf8.count)
        let pages = try XCTUnwrap(NotificationTextPaging.split(text))
        let firstPage = try XCTUnwrap(pages.first)
        XCTAssertTrue(pages.allSatisfy { $0.utf8.count <= NotificationTextPaging.maximumPageBytes })
        XCTAssertEqual(
            SHA256.hash(data: Data(pages.joined().utf8)), SHA256.hash(data: Data(text.utf8)))
        let first = UUID()
        view.show(firstPage, id: first)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(view.textView.textLayoutManager)
        XCTAssertGreaterThan(try XCTUnwrap(view.textView.textContainer).containerSize.width, 0)
        XCTAssertFalse(view.textView.isEditable)
        XCTAssertTrue(view.textView.isSelectable)
        XCTAssertEqual(view.textView.string, firstPage)
        view.textView.setSelectedRange(NSRange(location: 10, length: 4))
        view.show(firstPage, id: first)
        XCTAssertEqual(view.textView.selectedRange(), NSRange(location: 10, length: 4))

        let secondPage = try XCTUnwrap(pages.dropFirst().first)
        view.show(secondPage, id: first, page: 1)
        XCTAssertEqual(view.textView.string, secondPage)
        XCTAssertEqual(view.textView.selectedRange(), NSRange(location: 0, length: 0))

        view.show("Newest notification 🦉", id: UUID())
        XCTAssertEqual(view.textView.string, "Newest notification 🦉")
        XCTAssertEqual(view.textView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(view.contentView.bounds.origin, .zero)

        view.show("Another ordinary notification", id: UUID())
        XCTAssertEqual(view.textView.string, "Another ordinary notification")
    }

    func testOneLongParagraphKeepsItsFullText() throws {
        let view = NotificationTextScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let text = String(repeating: "x", count: 8 * 1024 * 1024)
        let pages = try XCTUnwrap(NotificationTextPaging.split(text))
        XCTAssertEqual(pages.joined(), text)
        view.show(try XCTUnwrap(pages.first), id: UUID())
        let layout = try XCTUnwrap(view.textView.textLayoutManager)
        XCTAssertTrue(layout.limitsLayoutForSuspiciousContents)
        layout.ensureLayout(for: CGRect(origin: .zero, size: view.contentSize))
        XCTAssertEqual(view.textView.string.utf8.count, NotificationTextPaging.maximumPageBytes)
        view.show("Next", id: UUID())
        XCTAssertEqual(view.textView.string, "Next")
    }

    func testPagingPreservesUnicodeAndLineBoundaries() throws {
        let text =
            String(repeating: "a", count: NotificationTextPaging.maximumPageBytes - 2)
            + "🦉" + String(repeating: "e\u{301}\n", count: 10_000)
        let pages = try XCTUnwrap(NotificationTextPaging.split(text))
        XCTAssertEqual(pages.joined(), text)
        XCTAssertEqual(pages.first?.utf8.count, NotificationTextPaging.maximumPageBytes - 2)
        XCTAssertTrue(pages.allSatisfy { $0.utf8.count <= NotificationTextPaging.maximumPageBytes })
        XCTAssertEqual(NotificationTextPaging.split("short"), ["short"])
    }
}
