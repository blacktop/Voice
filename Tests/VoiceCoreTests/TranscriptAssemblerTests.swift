import XCTest

@testable import VoiceCore

final class TranscriptAssemblerTests: XCTestCase {
    func testFinalResultReplacesOverlappingVolatileResult() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("hello wor", start: 0, duration: 0.8, final: false))
        assembler.apply(event("hello world", start: 0, duration: 1, final: true))

        XCTAssertEqual(assembler.transcript.text, "hello world")
        XCTAssertEqual(assembler.transcript.segments.count, 1)
        XCTAssertTrue(assembler.transcript.segments[0].isFinal)
    }

    func testVolatileUpdateCannotEraseFinalizedPrefix() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("hello", start: 0, duration: 0.5, final: true))
        assembler.apply(event("world", start: 0.45, duration: 0.5, final: false))

        XCTAssertEqual(assembler.transcript.text, "hello world")
        XCTAssertEqual(assembler.transcript.segments.count, 2)
    }

    func testLaterVolatileTailReplacesEarlierVolatileTail() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("a draft", start: 1, duration: 0.7, final: false))
        assembler.apply(event("the final draft", start: 1, duration: 1, final: false))

        XCTAssertEqual(assembler.transcript.text, "the final draft")
        XCTAssertEqual(assembler.transcript.segments.count, 1)
    }

    func testSegmentsArePresentedInAudioOrder() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("second", start: 2, duration: 0.5, final: true))
        assembler.apply(event("first", start: 0, duration: 0.5, final: true))

        XCTAssertEqual(assembler.transcript.text, "first second")
    }

    func testFinalSegmentWinsEqualStartTimeTieInPresentationOrder() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("final", start: 1, duration: 0, final: true))
        assembler.apply(event("draft", start: 1, duration: 0, final: false))

        XCTAssertEqual(assembler.transcript.text, "final draft")
        XCTAssertEqual(assembler.transcript.segments.count, 2)
        XCTAssertTrue(assembler.transcript.segments[0].isFinal)
        XCTAssertFalse(assembler.transcript.segments[1].isFinal)
    }

    func testAdjacentFinalizedChunksAreBothPreserved() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("first", start: 0, duration: 1, final: true))
        assembler.apply(event("second", start: 1, duration: 1, final: true))

        XCTAssertEqual(assembler.transcript.text, "first second")
        XCTAssertEqual(assembler.transcript.segments.count, 2)
    }

    func testFinalizedPrefixDoesNotEraseDisjointVolatileTail() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("draft tail", start: 2, duration: 1, final: false))
        assembler.apply(event("final prefix", start: 0, duration: 1, final: true))

        XCTAssertEqual(assembler.transcript.text, "final prefix draft tail")
        XCTAssertEqual(assembler.transcript.segments.count, 2)
    }

    func testBlankUpdateRemovesMatchingVolatileResultWithoutAddingText() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("temporary", start: 0, duration: 1, final: false))
        assembler.apply(event("   ", start: 0, duration: 1, final: true))

        XCTAssertTrue(assembler.transcript.text.isEmpty)
        XCTAssertTrue(assembler.transcript.segments.isEmpty)
    }

    func testVolatileReTranscribingFinalTailDoesNotDuplicateWords() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("hello world", start: 0, duration: 2, final: true))
        assembler.apply(event("world how are", start: 1.9, duration: 1.5, final: false))

        XCTAssertEqual(assembler.transcript.text, "hello world how are")
        XCTAssertEqual(assembler.transcript.segments.count, 2)
    }

    func testVolatileFullyCoveredByFinalizedAudioIsDropped() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("hello world", start: 0, duration: 2, final: true))
        assembler.apply(event("hello world", start: 0.5, duration: 1, final: false))

        XCTAssertEqual(assembler.transcript.text, "hello world")
        XCTAssertEqual(assembler.transcript.segments.count, 1)
    }

    func testResetClearsAllSegments() {
        var assembler = TranscriptAssembler()
        assembler.apply(event("hello", start: 0, duration: 1, final: true))

        assembler.reset()

        XCTAssertTrue(assembler.transcript.text.isEmpty)
        XCTAssertTrue(assembler.transcript.segments.isEmpty)
    }

    private func event(
        _ text: String,
        start: TimeInterval,
        duration: TimeInterval,
        final: Bool
    ) -> TranscriptEvent {
        TranscriptEvent(
            text: text,
            startTime: start,
            duration: duration,
            isFinal: final
        )
    }
}
