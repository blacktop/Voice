import ArgumentParser
import Darwin
import Foundation
import VoiceNotifications
import XCTest

final class NotificationDetailsInputTests: XCTestCase {
    private let required = [
        "--title", "Build", "--message", "Preview", "--group", "build", "--no-pane",
    ]

    func testFullDetailsPreserveLinesWhileOrdinaryPostsRemainCompatible() throws {
        let command = try PostNotification.parse(required + ["--details-stdin"])
        XCTAssertTrue(command.detailsStdin)
        let full = Data("First paragraph.\n\nFull details 🦉.\n".utf8)
        let details = try withInput(full) { try NotificationDetailsInput.read($0) }
        let message = try command.makeMessage(environment: [:], details: details)
        XCTAssertEqual(message.message, "Preview")
        XCTAssertEqual(message.details, full)
        XCTAssertFalse(message.push)
        XCTAssertNil(try command.makeMessage(environment: [:]).details)
        XCTAssertNil(
            try command.makeMessage(environment: [:], details: Data("Preview".utf8)).details)
        XCTAssertThrowsError(try PostNotification.parse(["--details-stdin", "--help"])) {
            XCTAssertEqual(VoiceNotify.exitCode(for: $0).rawValue, 0)
        }
    }

    func testFullDetailsAreBoundedAndValidatedBeforeDelivery() throws {
        let command = try PostNotification.parse(required + ["--details-stdin"])
        let limit = NotificationDetails.maximumTextBytes
        let exact = Data(repeating: 65, count: limit)
        XCTAssertEqual(try withInput(exact) { try NotificationDetailsInput.read($0) }, exact)
        XCTAssertThrowsError(
            try withInput(Data(repeating: 65, count: limit + 1)) {
                try NotificationDetailsInput.read($0)
            }
        ) { XCTAssertEqual(VoiceNotify.exitCode(for: $0).rawValue, 64) }
        for invalid in [Data(), Data([0xFF]), Data([0])] {
            let details = try withInput(invalid) { try NotificationDetailsInput.read($0) }
            XCTAssertThrowsError(try command.makeMessage(environment: [:], details: details))
        }
    }

    func testUnclosedPipeTimesOutAndRestoresDescriptorFlags() throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return XCTFail("could not create input pipe") }
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let flags = fcntl(descriptors[0], F_GETFL)
        let start = ContinuousClock.now
        XCTAssertThrowsError(
            try NotificationDetailsInput.read(descriptors[0], timeout: .milliseconds(20))
        ) {
            XCTAssertEqual(VoiceNotify.exitCode(for: $0).rawValue, 1)
            XCTAssertTrue($0.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(fcntl(descriptors[0], F_GETFL), flags)
    }

    func testInteractiveInputIsRejectedWithoutReading() throws {
        var master: Int32 = -1
        var terminal: Int32 = -1
        guard openpty(&master, &terminal, nil, nil, nil) == 0 else {
            throw XCTSkip("cannot allocate a pseudo-terminal")
        }
        defer {
            close(master)
            close(terminal)
        }
        XCTAssertThrowsError(try NotificationDetailsInput.read(terminal)) {
            XCTAssertEqual(VoiceNotify.exitCode(for: $0).rawValue, 64)
        }
    }

    private func withInput<T>(_ data: Data, body: (Int32) throws -> T) throws -> T {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let input = try FileHandle(forReadingFrom: path)
        defer { try? input.close() }
        return try body(input.fileDescriptor)
    }
}
