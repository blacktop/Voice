import AVFAudio
import Foundation

enum MLXAudioFileLoaderError: LocalizedError {
    case unreadable(String)
    case empty(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            "Could not read audio file \(name)."
        case .empty(let name):
            "Audio file \(name) contains no samples."
        case .conversionFailed(let name):
            "Could not convert \(name) to 16 kHz mono for the ASR models."
        }
    }
}

/// Reads an audio file (WAV, M4A, MP3, AIFF — anything AVAudioFile decodes)
/// and converts it to the 16 kHz mono Float32 samples the MLX ASR models
/// expect, matching the live-capture pipeline in MLXAudioCapture.
enum MLXAudioFileLoader {
    static func load(url: URL, sampleRate: Double = 16_000) throws -> MLXCapturedAudio {
        let name = url.lastPathComponent
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw MLXAudioFileLoaderError.unreadable(name)
        }
        guard file.length > 0,
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw MLXAudioFileLoaderError.empty(name)
        }
        do {
            try file.read(into: sourceBuffer)
        } catch {
            throw MLXAudioFileLoaderError.unreadable(name)
        }
        guard sourceBuffer.frameLength > 0 else {
            throw MLXAudioFileLoaderError.empty(name)
        }

        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat)
        else {
            throw MLXAudioFileLoaderError.conversionFailed(name)
        }
        converter.downmix =
            file.processingFormat.channelCount > outputFormat.channelCount

        let ratio = sampleRate / file.processingFormat.sampleRate
        let convertedFrames = (Double(sourceBuffer.frameLength) * ratio).rounded(.up)
        let capacity = AVAudioFrameCount(convertedFrames) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw MLXAudioFileLoaderError.conversionFailed(name)
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard conversionError == nil, status != .error else {
            throw MLXAudioFileLoaderError.conversionFailed(name)
        }
        let samples = try MLXAudioCapture.monoSamples(from: output)
        guard !samples.isEmpty else {
            throw MLXAudioFileLoaderError.empty(name)
        }
        return MLXCapturedAudio(samples: samples, sampleRate: sampleRate)
    }
}
