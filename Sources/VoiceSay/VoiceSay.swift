import ArgumentParser
import Foundation
import Synchronization
import VoiceMLX

/// `say`-shaped CLI for Voice's local Qwen3-TTS voices, so agents and scripts
/// can use the same on-device speech the app uses.
struct VoiceSay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voice-say",
        abstract: "Speak text with Voice's local Qwen3-TTS models.",
        discussion: """
            With no options the command speaks in the voice Voice's Settings is \
            configured to use, reusing the checkpoint the app already \
            downloaded. Each option overrides only what it names.

            Text comes from the operands, or from standard input when none are \
            given. The first use of a checkpoint downloads it from Hugging Face \
            into ~/Library/Application Support/io.blacktop.Voice/MLXModels; \
            synthesis then runs entirely on this Mac and the text and audio \
            never leave it.
            """,
        version: "0.1.0"
    )

    // Default parsing, not .captureForPassthrough: the latter swallows --help
    // and every other flag into the text. Text beginning with a dash still
    // works after the conventional `--` separator.
    @Argument(help: "The text to speak. Read from stdin when omitted.")
    var words: [String] = []

    @Option(
        name: .long,
        help: "Preset speaker: Ryan or Aiden.",
        completion: .list(MLXSpeechVoice.allCases.map(\.rawValue))
    )
    var voice: String?

    @Option(
        name: .long,
        help: "Model tier: small (0.6B, fast) or large (1.7B, higher quality).",
        completion: .list(MLXSpeechModelTier.allCases.map(\.rawValue))
    )
    var tier: String?

    @Option(
        name: .long,
        help: """
            Speech engine. Breeze TTS 2 is experimental, has no preset speakers \
            (use --describe or --clone), and ignores --tier.
            """
    )
    var engine: Engine?

    @Option(name: .long, help: "Delivery style, for example \"calm and unhurried\".")
    var style: String?

    @Option(
        name: .long,
        help: "Create a voice from a description. Always uses the 1.7B VoiceDesign model."
    )
    var describe: String?

    @Option(
        name: .long,
        help: ArgumentHelp("Clone from a 3-10s reference clip.", valueName: "path"),
        completion: .file()
    )
    var clone: String?

    @Option(name: .long, help: "The exact words spoken in the reference clip.")
    var cloneTranscript: String?

    @Flag(name: .shortAndLong, help: "Suppress model and progress output.")
    var quiet = false

    @Flag(
        name: .long,
        help: "Queue behind another instance instead of skipping when one is speaking."
    )
    var wait = false

    @Flag(name: .long, help: "List the preset voices and model tiers, then exit.")
    var listVoices = false

    mutating func validate() throws {
        if describe != nil, clone != nil {
            throw ValidationError("Choose only one of --describe or --clone.")
        }
        if let voice, Self.parseVoice(voice) == nil {
            let names = MLXSpeechVoice.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Unknown voice '\(voice)'. Available: \(names).")
        }
        if let tier, MLXSpeechModelTier(rawValue: tier.lowercased()) == nil {
            throw ValidationError("Unknown tier '\(tier)'. Use small or large.")
        }
        if engine == .breeze {
            if voice != nil {
                throw ValidationError(
                    "Breeze TTS 2 has no preset speakers, so --voice does not apply. "
                        + "Describe a voice with --describe or clone one with --clone."
                )
            }
            if tier != nil {
                throw ValidationError(
                    "--tier selects a Qwen3-TTS size and does not apply to --engine breeze."
                )
            }
        }
        if let clone {
            let transcript = cloneTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let transcript, !transcript.isEmpty else {
                throw ValidationError(
                    "--clone also needs --clone-transcript with the exact words in the clip."
                )
            }
            // Checked here rather than at synthesis time: the clip is not read
            // until after the checkpoint has downloaded and loaded, so a typo
            // would otherwise cost gigabytes and minutes before failing.
            let path = (clone as NSString).expandingTildeInPath
            guard FileManager.default.isReadableFile(atPath: path) else {
                throw ValidationError("Cannot read the reference clip at \(clone).")
            }
        }
    }

    func run() async throws {
        if listVoices {
            Self.printVoices()
            return
        }

        let options = try VoiceSayOptions(
            overrides: VoiceSayOverrides(
                voice: voice.flatMap(Self.parseVoice),
                family: engine?.family,
                tier: tier.flatMap { MLXSpeechModelTier(rawValue: $0.lowercased()) },
                style: style,
                description: describe,
                cloneURL: clone.map { URL(fileURLWithPath: $0) },
                cloneTranscript: cloneTranscript
            ),
            defaults: .fromAppPreferences()
        ).validated()

        // The app persists voice settings before validating them, so an
        // inherited clone can carry an unusable clip or empty transcript.
        // Reject it now: synthesis only reads the clip after loading the
        // checkpoint, which is a multi-gigabyte download on a cold cache.
        if case .cloned(let referenceURL, let transcript, _) = options.configuration {
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError(
                    "The cloned voice from Settings has no transcript. Pass "
                        + "--clone-transcript, or choose a preset with --voice."
                )
            }
            guard FileManager.default.isReadableFile(atPath: referenceURL.path) else {
                throw ValidationError(
                    "Cannot read the reference clip from Settings at "
                        + "\(referenceURL.path(percentEncoded: false))."
                )
            }
        }

        guard let text = Self.resolveText(words), !text.isEmpty else {
            throw ValidationError(
                "No text to speak. Pass text as arguments or pipe it on stdin."
            )
        }
        try await Self.speak(text, options: options, quiet: quiet, wait: wait)
    }

    private static func speak(
        _ text: String,
        options: VoiceSayOptions,
        quiet: Bool,
        wait: Bool
    ) async throws {
        // The MLX runtime prints model diagnostics to stdout. Speaking produces
        // no stdout output of its own, so redirect the descriptor to stderr and
        // keep stdout clean for callers that pipe this command.
        dup2(STDERR_FILENO, STDOUT_FILENO)

        // A queued announcement is stale by the time it is heard, so several
        // firing at once should collapse to one rather than becoming minutes of
        // backlog; --wait is for callers that want the utterance regardless.
        let busyMessage =
            wait
            ? "waiting for another voice-say to finish…"
            : "another voice-say is speaking; skipped. Use --wait to queue."

        // Skipping is the requested behaviour, not a failure, so the result is
        // discarded and the exit status stays 0.
        try await SpeechLock.withLock(
            whenBusy: wait ? .wait : .skip,
            onContended: {
                guard !quiet else { return }
                note(busyMessage)
            },
            body: { try await synthesize(text, options: options, quiet: quiet) }
        )
    }

    private static func synthesize(
        _ text: String,
        options: VoiceSayOptions,
        quiet: Bool
    ) async throws {
        if !quiet {
            // Announced only once the lock is held, so a skipped instance never
            // prints as though it were speaking.
            note(
                "using \(options.checkpoint.displayName) · "
                    + "\(describe(options.configuration))"
            )
        }
        let output = MLXSpeechOutput(
            checkpoint: options.checkpoint,
            configuration: options.configuration,
            onPreparation: { stage in
                guard !quiet else { return }
                report(stage)
            }
        )
        try await output.prepare()
        try await output.speak(text, voiceIdentifier: nil)
        await output.unload()
    }

    /// Progress goes to stderr so stdout stays clean for pipelines. A download
    /// reports many times per percent, so repeats are dropped rather than
    /// filling the terminal with identical lines.
    private static let lastProgressMessage = Mutex<String?>(nil)

    private static func report(_ stage: MLXModelPreparationStage) {
        let message: String
        switch stage {
        case .downloading(let fraction):
            message = "downloading \(fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .loading:
            message = "loading model"
        case .ready:
            message = "ready"
        }
        let shouldPrint = lastProgressMessage.withLock { last -> Bool in
            guard last != message else { return false }
            last = message
            return true
        }
        guard shouldPrint else { return }
        note(message)
    }

    /// Operands win; otherwise read stdin so `... | voice-say` works.
    private static func resolveText(_ words: [String]) -> String? {
        if !words.isEmpty {
            return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let piped = String(data: data, encoding: .utf8) else { return nil }
        return piped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func describe(_ configuration: MLXVoiceConfiguration) -> String {
        switch configuration {
        case .preset(let voice, let style):
            let styled = style.map { " · \($0)" } ?? ""
            return "voice \(voice.displayName)\(styled)"
        case .designed(let description):
            return "described voice: \(description)"
        case .cloned(let url, _, let style):
            let styled = style.map { " · \($0)" } ?? ""
            return "cloned from \(url.lastPathComponent)\(styled)"
        }
    }

    private static func printVoices() {
        print("Preset voices:")
        for voice in MLXSpeechVoice.allCases {
            print("  \(voice.rawValue)")
        }
        print("")
        print("Tiers:")
        for tier in MLXSpeechModelTier.allCases {
            let checkpoint = MLXSpeechCheckpoint.checkpoint(
                tier: tier,
                configuration: .preset(.ryan, style: nil)
            )
            print("  \(tier.rawValue) — \(checkpoint.displayName)")
            print("      download \(checkpoint.approximateDownload)")
        }
    }

    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("voice-say: \(message)\n".utf8))
    }

    /// Voice names are matched case-insensitively so "aiden" works as well as
    /// the "Aiden" that the model catalogue spells.
    private static func parseVoice(_ name: String) -> MLXSpeechVoice? {
        MLXSpeechVoice.allCases.first {
            $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
        }
    }
}

/// `--engine` values. A CLI-local type rather than `MLXSpeechModelFamily` so
/// the argument spelling can stay stable if the model families are renamed.
enum Engine: String, CaseIterable, ExpressibleByArgument {
    case qwen3
    case breeze

    var family: MLXSpeechModelFamily {
        switch self {
        case .qwen3: .qwen3
        case .breeze: .breeze
        }
    }
}
