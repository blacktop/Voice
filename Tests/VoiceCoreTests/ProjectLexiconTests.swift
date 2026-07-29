import Foundation
import XCTest

@testable import VoiceCore

final class ProjectLexiconTests: XCTestCase {
    func testUsesNamesButNeverFileContentsAndSkipsExcludedTrees() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }

        try fixture.createFile("Sources/SpeechPipeline.swift", contents: "ContentOnlySecretToken")
        try fixture.createFile("FeaturePlanning/AgentTransport.swift")
        try fixture.createFile(".hidden/InvisibleToken.swift")
        try fixture.createFile("build/BuildOnlyToken.swift")
        try fixture.createFile("vendor/VendorOnlyToken.swift")

        let outsideURL = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let outsideFile = outsideURL.appendingPathComponent("OutsideSecretToken.swift")
        try Data().write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: fixture.rootURL.appendingPathComponent("linked-outside"),
            withDestinationURL: outsideURL
        )

        let terms = try await ProjectLexicon().contextualStrings(in: fixture.rootURL)

        XCTAssertTrue(terms.contains("SpeechPipeline.swift"), "Derived terms: \(terms)")
        XCTAssertTrue(terms.contains("SpeechPipeline"), "Derived terms: \(terms)")
        XCTAssertTrue(terms.contains("FeaturePlanning"), "Derived terms: \(terms)")
        XCTAssertTrue(terms.contains("AgentTransport"), "Derived terms: \(terms)")

        let allTerms = terms.joined(separator: " ")
        XCTAssertFalse(allTerms.contains("ContentOnlySecretToken"))
        XCTAssertFalse(allTerms.contains("InvisibleToken"))
        XCTAssertFalse(allTerms.contains("BuildOnlyToken"))
        XCTAssertFalse(allTerms.contains("VendorOnlyToken"))
        XCTAssertFalse(allTerms.contains("OutsideSecretToken"))
        XCTAssertFalse(allTerms.contains("linked-outside"))
    }

    func testAlwaysCapsResultsAtOneHundredAndIsStable() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }

        for index in 0..<150 {
            try fixture.createFile("Feature\(index)/UniqueIdentifier\(index).swift")
        }

        let lexicon = ProjectLexicon(
            configuration: .init(maximumTerms: 500, maximumEntries: 10_000)
        )
        let first = try await lexicon.contextualStrings(in: fixture.rootURL)
        let second = try await lexicon.contextualStrings(in: fixture.rootURL)

        XCTAssertEqual(first.count, 100)
        XCTAssertEqual(first, second)
    }

    func testRejectsASelectedFileInsteadOfScanningItsParent() async throws {
        let fixture = try TemporaryProjectFixture()
        defer { fixture.remove() }
        try fixture.createFile("NotADirectory.swift")

        let fileURL = fixture.rootURL.appendingPathComponent("NotADirectory.swift")
        do {
            _ = try await ProjectLexicon().contextualStrings(in: fileURL)
            XCTFail("Expected a non-directory project selection to be rejected")
        } catch let error as ProjectLexiconError {
            XCTAssertEqual(error, .projectIsNotDirectory)
        }
    }
}

private struct TemporaryProjectFixture {
    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func createFile(_ relativePath: String, contents: String = "") throws {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
