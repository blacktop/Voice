import Foundation

enum MLXShortAudioSilenceAssessment {
    private static let maximumDuration: TimeInterval = 4
    private static let peakThreshold: Float = 0.01
    private static let overallRMSThreshold: Float = 0.002
    private static let frameRMSThreshold: Float = 0.0045

    static func isSilent(samples: [Float], sampleRate: Double) -> Bool {
        guard !samples.isEmpty, sampleRate > 0,
            Double(samples.count) / sampleRate < maximumDuration
        else {
            return false
        }

        var peak: Float = 0
        var sumSquares: Double = 0
        for sample in samples {
            guard sample.isFinite else { return false }
            peak = max(peak, abs(sample))
            // Squared in Double: near-silence is exactly where a Float square
            // flushes to a denormal and loses the level being measured.
            sumSquares += Double(sample) * Double(sample)
        }
        let overallRMS = Float(sqrt(sumSquares / Double(samples.count)))

        let frameLength = max(1, Int((sampleRate * 0.02).rounded()))
        var maximumFrameRMS: Float = 0
        var frameStart = 0
        while frameStart < samples.count {
            let frameEnd = min(frameStart + frameLength, samples.count)
            var frameSquares: Double = 0
            for sample in samples[frameStart..<frameEnd] {
                frameSquares += Double(sample) * Double(sample)
            }
            let frameRMS = Float(
                sqrt(frameSquares / Double(frameEnd - frameStart))
            )
            maximumFrameRMS = max(maximumFrameRMS, frameRMS)
            frameStart = frameEnd
        }

        return peak < peakThreshold
            && overallRMS < overallRMSThreshold
            && maximumFrameRMS < frameRMSThreshold
    }
}
