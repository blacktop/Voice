import Foundation
import XCTest

@testable import VoicePlatform

final class ZedACPAgentDiscoveryTests: XCTestCase {
    func testDiscoversNewestZedNpmLaunchersAndUsesAbsoluteNode() throws {
        let fixture = try ZedACPDiscoveryFixture()
        defer { fixture.cleanup() }
        let olderClaude = try fixture.makeNpmLauncher(
            agent: "claude-agent-acp",
            cacheKey: "older",
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let newerClaude = try fixture.makeNpmLauncher(
            agent: "claude-agent-acp",
            cacheKey: "newer",
            modifiedAt: Date(timeIntervalSince1970: 20)
        )
        _ = try fixture.makeNpmLauncher(
            agent: "codex-acp",
            cacheKey: "codex",
            modifiedAt: Date(timeIntervalSince1970: 15)
        )
        XCTAssertNotEqual(olderClaude, newerClaude)

        let choices = ZedACPAgentDiscovery(zedDataURL: fixture.zedDataURL).discover()
        let claude = try XCTUnwrap(choices.first { $0.agent == .claude })
        let codex = try XCTUnwrap(choices.first { $0.agent == .codex })

        XCTAssertEqual(
            claude.executableURL.resolvingSymlinksInPath(),
            fixture.nodeURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(claude.arguments, [newerClaude.resolvingSymlinksInPath().path])
        XCTAssertEqual(
            codex.executableURL.resolvingSymlinksInPath(),
            fixture.nodeURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(codex.sourceDescription, "Zed ACP registry cache")
    }

    func testNewestRegistryNpmLauncherWinsOverOlderStandaloneBinary() throws {
        let fixture = try ZedACPDiscoveryFixture()
        defer { fixture.cleanup() }
        let npmLauncher = try fixture.makeNpmLauncher(
            agent: "codex-acp",
            cacheKey: "current",
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        _ = try fixture.makeExecutable(
            at: "external_agents/codex/v9/codex-acp",
            modifiedAt: Date(timeIntervalSince1970: 5)
        )

        let choices = ZedACPAgentDiscovery(zedDataURL: fixture.zedDataURL).discover()
        let codex = try XCTUnwrap(choices.first { $0.agent == .codex })

        XCTAssertEqual(
            codex.executableURL.resolvingSymlinksInPath(),
            fixture.nodeURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(codex.arguments, [npmLauncher.resolvingSymlinksInPath().path])
        XCTAssertEqual(codex.sourceDescription, "Zed ACP registry cache")
    }

    func testNewerStandaloneBinaryWinsOverStaleNpmCache() throws {
        let fixture = try ZedACPDiscoveryFixture()
        defer { fixture.cleanup() }
        _ = try fixture.makeNpmLauncher(
            agent: "codex-acp",
            cacheKey: "stale",
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let binary = try fixture.makeExecutable(
            at: "external_agents/registry/codex-acp/v_2/codex-acp",
            modifiedAt: Date(timeIntervalSince1970: 20)
        )

        let choices = ZedACPAgentDiscovery(zedDataURL: fixture.zedDataURL).discover()
        let codex = try XCTUnwrap(choices.first { $0.agent == .codex })

        XCTAssertEqual(
            codex.executableURL.resolvingSymlinksInPath(),
            binary.resolvingSymlinksInPath()
        )
        XCTAssertTrue(codex.arguments.isEmpty)
        XCTAssertEqual(codex.sourceDescription, "Zed external agent")
    }

    func testFallsBackToStandaloneZedBinaryWhenNpmCacheIsAbsent() throws {
        let fixture = try ZedACPDiscoveryFixture()
        defer { fixture.cleanup() }
        let binary = try fixture.makeExecutable(
            at: "external_agents/registry/codex-acp/v_1/codex-acp",
            modifiedAt: Date(timeIntervalSince1970: 50)
        )

        let choices = ZedACPAgentDiscovery(zedDataURL: fixture.zedDataURL).discover()
        let codex = try XCTUnwrap(choices.first { $0.agent == .codex })

        XCTAssertEqual(
            codex.executableURL.resolvingSymlinksInPath(),
            binary.resolvingSymlinksInPath()
        )
        XCTAssertTrue(codex.arguments.isEmpty)
        XCTAssertEqual(codex.sourceDescription, "Zed external agent")
    }
}

private struct ZedACPDiscoveryFixture {
    let rootURL: URL
    let zedDataURL: URL
    let nodeURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZedACPAgentDiscoveryTests-\(UUID().uuidString)")
        zedDataURL = rootURL.appendingPathComponent("Zed", isDirectory: true)
        nodeURL =
            zedDataURL
            .appendingPathComponent("node/node-v99-darwin-arm64/bin/node")
        try FileManager.default.createDirectory(
            at: nodeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: nodeURL.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: nodeURL.path
        )
    }

    func makeNpmLauncher(
        agent: String,
        cacheKey: String,
        modifiedAt: Date
    ) throws -> URL {
        let packageDirectory =
            zedDataURL
            .appendingPathComponent("node/cache/_npx/\(cacheKey)/node_modules")
        let targetURL =
            packageDirectory
            .appendingPathComponent("@agentclientprotocol/\(agent)/dist/index.js")
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: targetURL.path, contents: Data()))
        try FileManager.default.setAttributes(
            [
                .modificationDate: modifiedAt,
                .posixPermissions: 0o755,
            ],
            ofItemAtPath: targetURL.path
        )

        let launcherDirectory = packageDirectory.appendingPathComponent(".bin")
        try FileManager.default.createDirectory(
            at: launcherDirectory,
            withIntermediateDirectories: true
        )
        let launcherURL = launcherDirectory.appendingPathComponent(agent)
        try FileManager.default.createSymbolicLink(
            at: launcherURL,
            withDestinationURL: targetURL
        )
        return launcherURL
    }

    func makeExecutable(at relativePath: String, modifiedAt: Date) throws -> URL {
        let url = zedDataURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        try FileManager.default.setAttributes(
            [
                .modificationDate: modifiedAt,
                .posixPermissions: 0o755,
            ],
            ofItemAtPath: url.path
        )
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
