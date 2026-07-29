import VoiceCore
import XCTest

@testable import VoicePlatform

final class AppleFoundationModelCleanerPolicyTests: XCTestCase {
    func testOnlyPolishUsesFoundationModels() {
        XCTAssertFalse(
            CleanupExecutionPolicy.usesFoundationModels(for: .conservative)
        )
        XCTAssertTrue(
            CleanupExecutionPolicy.usesFoundationModels(for: .polish)
        )
    }
}
