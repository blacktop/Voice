import VoiceCore
import XCTest

final class AudioCaptureReadinessTests: XCTestCase {
    func testReturnsTrueAfterFirstBuffer() async {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        pair.continuation.yield(())

        let ready = await AudioCaptureReadiness.wait(
            for: pair.stream,
            timeout: .seconds(1)
        )

        XCTAssertTrue(ready)
    }

    func testReturnsFalseWhenNoBufferArrives() async {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

        let ready = await AudioCaptureReadiness.wait(
            for: pair.stream,
            timeout: .milliseconds(10)
        )

        XCTAssertFalse(ready)
        pair.continuation.finish()
    }
}
