import AVFAudio
import Speech
import XCTest

@testable import VoicePlatform

final class MicrophoneInputTests: XCTestCase {
    func testConvertedLiveBufferAppendsToAnalyzerTimeline() throws {
        // macOS 27 deprecated AnalyzerInput(buffer:) and traps inside
        // Speech.framework for every buffer, so the legacy path this exercises
        // only runs on macOS 26; AnalyzerInputConversion replaces it on 27.
        try XCTSkipIf(
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27,
            "AnalyzerInput.init(buffer:) is deprecated and traps on macOS 27"
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 342)
        )
        buffer.frameLength = 342

        let input = try XCTUnwrap(MicrophoneInput.makeAnalyzerInput(buffer: buffer))

        XCTAssertNil(input.bufferStartTime)
    }

    /// The macOS 27 replacement for the trapping AnalyzerInput(buffer:) path:
    /// resamples microphone audio to the analyzer format and yields inputs
    /// without crashing. Guards the migration that restored Apple dictation.
    func testAnalyzerInputConversionResamplesMicrophoneAudio() async throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("AnalyzerInputConverter requires macOS 27")
        }
        let conversion = try await Self.makeConversion()

        let micFormat = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: 4_800)
        )
        buffer.frameLength = 4_800
        if let channel = buffer.floatChannelData {
            for frame in 0..<4_800 { channel.pointee[frame] = 0 }
        }

        let inputs = try conversion.convert(buffer, at: nil)
        XCTAssertFalse(inputs.isEmpty, "converter produced no analyzer inputs")
        let analyzerFormat = try XCTUnwrap(inputs.first?.bufferFormat)
        XCTAssertEqual(analyzerFormat.sampleRate, 16_000)
        XCTAssertEqual(analyzerFormat.channelCount, 1)
    }

    /// stop() flushes to recover the tail of a short utterance. Asserting the
    /// flush actually yields audio is the point: returning [] here silently
    /// truncates the end of every dictation.
    func testAnalyzerInputConversionFlushDrainsBufferedAudio() async throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("AnalyzerInputConverter requires macOS 27")
        }
        let conversion = try await Self.makeConversion()
        // A frame count that does not divide evenly into the analyzer's rate
        // leaves a remainder in the resampler for flush() to drain.
        _ = try conversion.convert(Self.silentBuffer(frames: 999), at: nil)
        let drained = try conversion.flush()
        XCTAssertFalse(drained.isEmpty, "flush produced no audio; the tail would be lost")
    }

    /// The conversion is documented as serialising the capture thread's
    /// convert() against flush() on stop. Removing the lock must be visible.
    func testAnalyzerInputConversionSurvivesConcurrentConvertAndFlush() async throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("AnalyzerInputConverter requires macOS 27")
        }
        let conversion = try await Self.makeConversion()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<20 {
                        _ = try? conversion.convert(Self.silentBuffer(frames: 512), at: nil)
                    }
                }
                group.addTask {
                    for _ in 0..<20 {
                        _ = try? conversion.flush()
                    }
                }
            }
        }
        // Reaching here without a crash or trap is the assertion; the converter
        // keeps mutable resampler state that is not thread-safe on its own.
        XCTAssertNoThrow(try conversion.flush())
    }

    func testFlushFailureFinishesInputStreamWithError() async {
        let pair = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()

        MicrophoneInput.finishInputStream(pair.continuation) {
            throw TestFlushError.failed
        }

        do {
            for try await _ in pair.stream {}
            XCTFail("Expected the converter flush error to reach the input stream")
        } catch let error as TestFlushError {
            XCTAssertEqual(error, .failed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @available(macOS 27, *)
    /// The converter derives the analyzer format from the module's installed
    /// speech assets, so a machine without the en-US dictation model (a fresh
    /// CI runner) cannot create one. That is an environment gap, not a
    /// regression, so the test skips. `installedLocales` is the signal that
    /// matches reality: `AssetInventory.status` reports only app-managed
    /// installs and answers `supported` even where system dictation works.
    private static func makeConversion() async throws -> AnalyzerInputConversion {
        let locale = Locale(identifier: "en-US")
        let installed = await DictationTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
        else {
            throw XCTSkip("en-US dictation assets are not installed on this machine")
        }
        let transcriber = DictationTranscriber(
            locale: locale,
            preset: .progressiveShortDictation
        )
        return try await AnalyzerInputConversion.make(compatibleWith: [transcriber])
    }

    private static func silentBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData {
            for frame in 0..<Int(frames) { channel.pointee[frame] = 0 }
        }
        return buffer
    }

    func testEmptyConvertedBufferIsNotSubmitted() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 342)
        )

        XCTAssertNil(MicrophoneInput.makeAnalyzerInput(buffer: buffer))
    }

    func testRoundedConvertedBufferCanOutlastNextSourceTimestamp() {
        let convertedBufferEnd = 342.0 / 16_000.0
        let nextSourceTimestamp = 1_024.0 / 48_000.0

        XCTAssertLessThan(nextSourceTimestamp, convertedBufferEnd)
    }
}

private enum TestFlushError: Error {
    case failed
}
