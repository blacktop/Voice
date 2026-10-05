import Foundation

/// The voice for each narration role, cast from the narrator's own voice.
///
/// One checkpoint is loaded per narration, so every role must be servable by
/// the narrator's checkpoint. Preset narrators hand the other roles to the
/// checkpoint's other preset speaker. A described voice has no second
/// speaker, so its roles keep the speaker and change the delivery. A cloned
/// voice reads every role unchanged.
public struct MLXNarrationVoices: Equatable, Sendable {
    public let narrator: MLXVoiceConfiguration
    public let heading: MLXVoiceConfiguration
    public let aside: MLXVoiceConfiguration
    public let quote: MLXVoiceConfiguration

    static let headingStyle = "announcing a section title, clear and brisk"
    static let asideStyle = "a brief, quiet, matter-of-fact aside"
    static let quoteStyle = "reading a quotation aloud, unhurried and deliberate"

    public static func cast(narrator: MLXVoiceConfiguration) -> MLXNarrationVoices {
        switch narrator {
        case .preset(let voice, _):
            let other = voice.counterpart
            return MLXNarrationVoices(
                narrator: narrator,
                heading: .preset(other, style: headingStyle),
                aside: .preset(other, style: asideStyle),
                quote: .preset(other, style: quoteStyle)
            )
        case .designed(let description):
            return MLXNarrationVoices(
                narrator: narrator,
                heading: .designed(description: joined(description, headingStyle)),
                aside: .designed(description: joined(description, asideStyle)),
                quote: .designed(description: joined(description, quoteStyle))
            )
        case .cloned:
            // The Base checkpoint has no instruction following, and a style
            // on a clone also forfeits the cached reference conditioning, so
            // a cloned narrator reads every role itself.
            return MLXNarrationVoices(
                narrator: narrator, heading: narrator, aside: narrator, quote: narrator
            )
        }
    }

    public func configuration(for role: SpeechNarrationRole) -> MLXVoiceConfiguration {
        switch role {
        case .narrator: narrator
        case .heading: heading
        case .aside: aside
        case .quote: quote
        }
    }

    /// The preset speaker reading every role but the narrator's, when the
    /// cast has one.
    public var secondSpeaker: MLXSpeechVoice? {
        guard case .preset(let voice, _) = heading else { return nil }
        return voice
    }

    private static func joined(_ description: String, _ style: String) -> String {
        let base = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return style }
        let punctuated = base.last.map { ".!?".contains($0) } == true ? base : base + "."
        return "\(punctuated) \(style.prefix(1).uppercased())\(style.dropFirst())."
    }
}
