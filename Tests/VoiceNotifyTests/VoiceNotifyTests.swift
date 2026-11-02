import ArgumentParser
import VoiceNotifications
import XCTest

final class VoiceNotifyTests: XCTestCase {
    private let required = ["--title", "Build", "--message", "Passed", "--group", "build"]

    func testRootRoutesPostingAndConfigurationIndependently() throws {
        XCTAssertTrue(try VoiceNotify.parseAsRoot(required + ["--no-pane"]) is PostNotification)
        XCTAssertTrue(
            try VoiceNotify.parseAsRoot([
                "configure-push", "--server", "https://example.test", "--topic", "private",
            ]) is ConfigurePush)
    }

    func testRequiredArgumentsAndUsageExitCode() throws {
        XCTAssertNoThrow(try PostNotification.parse(required + ["--no-pane"]))
        for arguments in [
            [], ["--title", "Build"], required + ["--unknown"],
            required + ["--pane", "%3", "--no-pane"], required + ["--pane", "3"],
        ] {
            XCTAssertThrowsError(try PostNotification.parse(arguments)) { error in
                XCTAssertEqual(VoiceNotify.exitCode(for: error).rawValue, 64)
            }
        }
        XCTAssertEqual(
            VoiceNotify.exitCode(for: VoiceNotificationError("delivery failed")).rawValue, 1)
    }

    func testPaneAndServerDefaultsAreExplicitAndDeterministic() throws {
        let environment = ["TMUX_PANE": "%8", "TMUX": "/tmp/server,123,0"]
        let command = try PostNotification.parse(required)
        XCTAssertNil(try command.makeMessage(environment: environment).details)
        XCTAssertEqual(try command.makeMessage(environment: environment).pane, "%8")
        XCTAssertEqual(try command.makeMessage(environment: environment).tmuxSocket, "/tmp/server")
        let disabled = try PostNotification.parse(required + ["--no-pane"])
        XCTAssertNil(try disabled.makeMessage(environment: environment).pane)
        let explicit = try PostNotification.parse(
            required + ["--pane", "%2", "--tmux-socket", "/tmp/other"])
        XCTAssertEqual(try explicit.makeMessage(environment: environment).pane, "%2")
        XCTAssertEqual(try explicit.makeMessage(environment: environment).tmuxSocket, "/tmp/other")
    }

    func testPushIsOptInAndConfigureDoesNotAcceptTokenArgument() throws {
        let environment = ["VOICE_NOTIFY_NTFY_TOKEN": "secret"]
        XCTAssertNil(
            try PostNotification.parse(required + ["--no-pane"]).makeMessage(
                environment: environment
            )
            .pushOverrides)
        XCTAssertEqual(
            try PostNotification.parse(required + ["--no-pane", "--push"]).makeMessage(
                environment: environment
            ).pushOverrides?.token, "secret")
        XCTAssertTrue(
            try ConfigurePush.parse([
                "--server", "https://example.test", "--topic", "private", "--token-stdin",
            ]).tokenStdin)
        XCTAssertThrowsError(
            try ConfigurePush.parse(["--server", "http://example.test", "--topic", "private"]))
        XCTAssertThrowsError(
            try ConfigurePush.parse([
                "--server", "https://example.test", "--topic", "private", "--token", "secret",
            ]))
    }

    func testZedProjectCanBeCombinedWithOrWithoutTmux() throws {
        let project = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let environment = ["TMUX_PANE": "%8", "TMUX": "/tmp/server,123,0"]
        let command = try PostNotification.parse(required + ["--zed-project", project])
        let combined = try command.makeMessage(environment: environment)
        XCTAssertEqual(combined.zedProject, project)
        XCTAssertEqual(combined.pane, "%8")
        XCTAssertEqual(combined.tmuxSocket, "/tmp/server")
        XCTAssertFalse(combined.push)
        let standalone = try PostNotification.parse(
            required + ["--zed-project", project, "--no-pane"])
        XCTAssertEqual(try standalone.makeMessage(environment: environment).zedProject, project)
        XCTAssertNil(try standalone.makeMessage(environment: environment).pane)
        XCTAssertThrowsError(try PostNotification.parse(required + ["--zed-project", "relative"])) {
            XCTAssertEqual(VoiceNotify.exitCode(for: $0).rawValue, 64)
        }
    }

    func testHelpDoesNotPost() {
        XCTAssertThrowsError(try PostNotification.parse(["--help"])) { error in
            XCTAssertEqual(VoiceNotify.exitCode(for: error).rawValue, 0)
        }
    }

    func testNativeRexFlagsAndDefaults() throws {
        let session = "session:00000000-0000-0000-0000-000000000001"
        let block = "block:00000000-0000-0000-0000-000000000002"
        let environment = [
            "REX_SESSION": session, "REX_BLOCK": block, "REX_SERVER": "/tmp/rex.sock",
        ]
        let automatic = try PostNotification.parse(required + ["--no-pane"])
        XCTAssertEqual(try automatic.makeMessage(environment: environment).rex?.block, block)
        let disabled = try PostNotification.parse(required + ["--no-pane", "--no-rex"])
        XCTAssertNil(try disabled.makeMessage(environment: environment).rex)
        let explicit = [
            "--rex-session", session, "--rex-block", block, "--rex-server", "/tmp/rex.sock",
        ]
        let command = try PostNotification.parse(required + explicit)
        XCTAssertEqual(try command.makeMessage(environment: [:]).rex?.session, session)
        for flags in [
            explicit + ["--pane", "%3"], explicit + ["--no-rex"],
            ["--rex-session", "short", "--rex-block", block],
            explicit + ["--rex-client", "ambiguous-label"],
        ] {
            XCTAssertThrowsError(try PostNotification.parse(required + flags)) {
                XCTAssertEqual(VoiceNotify.exitCode(for: $0).rawValue, 64)
            }
        }
    }
}
