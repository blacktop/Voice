import ArgumentParser
import Foundation
import Synchronization
import VoiceMLX
import VoiceMLXRuntime
import VoiceNotifications
import VoicePlatform

/// `say`-shaped CLI for Voice's local Qwen3-TTS voices, so agents and scripts
/// can use the same on-device speech the app uses.
struct VoiceSay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voice-say",
        abstract: "Speak text with Voice's local Qwen3-TTS models.",
        discussion: """
            With no options the command speaks in the voice Voice's Settings is \
            configured to use, reusing the checkpoint the app already \
            downloaded. If the app selects Breeze, the CLI uses Qwen3 instead; \
            Breeze requires --engine breeze with --describe or --clone. \
            Each option overrides only what it names.

            Text comes from the operands, --file (UTF-8 text or Markdown), or \
            standard input. Operands are spoken as plain text and streamed. \
            Files and stdin use Markdown narration, which prepares a paragraph ahead of \
            playback, summarizes code blocks and URLs, and leaves a longer rest \
            between paragraphs. Headings, quotations, and the labels standing \
            in for omitted material are read by the checkpoint's other preset \
            speaker. --speed stretches playback without changing pitch. Use \
            --stream for lower startup latency without pause normalization, \
            and --timings to diagnose synthesis speed and playback gaps.

            In interactive --file mode, Space pauses/resumes without Enter. \
            --announce-pause adds spoken feedback; --no-controls disables keys. \
            Tables are announced briefly rather than read cell by cell.

            The first use of a checkpoint downloads it from Hugging Face \
            into ~/Library/Application Support/io.blacktop.Voice/MLXModels; \
            synthesis then runs entirely on this Mac. --notify posts a short \
            text preview after acquiring the speech lock; --notify-push also \
            sends that notification to the configured ntfy server.
            """,
        version: "0.1.0"
    )

    // Default parsing, not .captureForPassthrough: the latter swallows --help
    // and every other flag into the text. Text beginning with a dash still
    // works after the conventional `--` separator.
    @Argument(help: "The text to speak. Read from stdin when omitted.")
    var words: [String] = []

    @Option(
        name: [.short, .long],
        help: "Read a UTF-8 text/Markdown document, up to 4 MiB (- for stdin).",
        completion: .file())
    var file: String?

    @Flag(
        name: .long,
        help: "Play raw model chunks immediately instead of preparing narration segments.")
    var stream = false

    @Flag(
        name: .long,
        help: "Report per-segment synthesis, audio, silence trimming, and queue timings to stderr.")
    var timings = false

    @Flag(name: .long, help: "Disable Space pause/resume controls for file narration.")
    var noControls = false

    @Flag(name: .long, help: "Say 'Paused' with the system voice when Space pauses file narration.")
    var announcePause = false

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
        help: """
            Sampling temperature, 0 to 1.5. Lower keeps the voice steadier from \
            one utterance to the next; higher is more expressive. The model's \
            own default is 0.9.
            """
    )
    var temperature: Float = 0.6

    @Option(
        name: .long,
        help: """
            Playback speed, 0.5 to 2. Stretches time without changing pitch, \
            so 1.2 reads a fifth faster and shortens every pause the same way.
            """
    )
    var speed: Float = 1

    @Option(
        name: .long,
        help: """
            Restart the sampler from this seed for every utterance, so a \
            document narrates the same way each time and the opening of each \
            utterance draws the same noise.
            """
    )
    var seed: UInt64?

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

    @OptionGroup var notification: VoiceSayNotificationOptions

    mutating func validate() throws {
        try validateInput()
        try validateSampling()
        try validateVoiceNames()
        try validateBreeze()
        try validateClone()
    }

    private func validateInput() throws {
        if announcePause, file == nil || noControls {
            throw ValidationError(
                "--announce-pause requires --file with terminal controls enabled.")
        }
        if file != nil, !words.isEmpty {
            throw ValidationError("Choose either --file or text arguments, not both.")
        }
    }

    private func validateSampling() throws {
        guard temperature.isFinite, (0...1.5).contains(temperature) else {
            throw ValidationError("--temperature must be between 0 and 1.5.")
        }
        guard speed.isFinite, (0.5...2).contains(speed) else {
            throw ValidationError("--speed must be between 0.5 and 2.")
        }
    }

    private func validateVoiceNames() throws {
        if let voice, Self.parseVoice(voice) == nil {
            let names = MLXSpeechVoice.allCases.map(\.rawValue).joined(separator: ", ")
            throw ValidationError("Unknown voice '\(voice)'. Available: \(names).")
        }
        if let tier, MLXSpeechModelTier(rawValue: tier.lowercased()) == nil {
            throw ValidationError("Unknown tier '\(tier)'. Use small or large.")
        }
    }

    private func validateBreeze() throws {
        guard engine == .breeze else { return }
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

    private func validateClone() throws {
        if describe != nil, clone != nil {
            throw ValidationError("Choose only one of --describe or --clone.")
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

        let (blocks, streaming) = try resolveInput()
        let narration = NarrationOptions(
            streaming: streaming,
            timings: timings,
            controls: file != nil && !noControls,
            announcePause: announcePause,
            sampling: MLXTTSSampling(
                temperature: temperature, topK: MLXSpeechOutput.defaultSampling.topK,
                topP: MLXSpeechOutput.defaultSampling.topP, seed: seed),
            speed: speed
        )
        try await Self.speak(
            blocks, options: options, narration: narration, quiet: quiet, wait: wait,
            notification: try notification.message(
                previewParts: blocks.lazy.map(\.text),
                environment: ProcessInfo.processInfo.environment)
        )
    }

    /// Delivery flags that only matter once text and voice are resolved.
    private struct NarrationOptions {
        var streaming: Bool
        var timings: Bool
        var controls: Bool
        var announcePause: Bool
        var sampling: MLXTTSSampling
        var speed: Float
    }

    private static func speak(
        _ blocks: [SpeechNarrationBlock],
        options: VoiceSayOptions,
        narration: NarrationOptions,
        quiet: Bool,
        wait: Bool,
        notification: NotificationMessage?
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
        try await VoiceSayNotificationFlow.run(
            message: notification,
            whenBusy: wait ? .wait : .skip,
            onContended: {
                guard !quiet else { return }
                note(busyMessage)
            },
            report: { note($0) },
            post: { try await NotificationClient.send(.post($0)) },
            speak: {
                try await synthesize(blocks, options: options, narration: narration, quiet: quiet)
            }
        )
    }

    private static func synthesize(
        _ blocks: [SpeechNarrationBlock],
        options: VoiceSayOptions,
        narration: NarrationOptions,
        quiet: Bool
    ) async throws {
        if !quiet {
            // Announced only once the lock is held, so a skipped instance never
            // prints as though it were speaking.
            note(
                "using \(options.checkpoint.displayName) · "
                    + "\(describe(options.configuration))"
            )
            if let second = MLXNarrationVoices.cast(narrator: options.configuration).secondSpeaker,
                blocks.contains(where: { $0.role != .narrator })
            {
                note("headings, quotes, and asides: voice \(second.displayName)")
            }
            let seed = narration.sampling.seed.map { " · seed \($0)" } ?? ""
            let speed = narration.speed == 1 ? "" : " · speed \(narration.speed)x"
            note("temperature \(narration.sampling.temperature ?? 0.9)\(seed)\(speed)")
        }
        let output = MLXSpeechOutput(
            checkpoint: options.checkpoint,
            configuration: options.configuration,
            sampling: narration.sampling,
            playbackRate: narration.speed,
            onPreparation: { stage in
                guard !quiet else { return }
                report(stage)
            }
        )
        do {
            let started = ContinuousClock.now
            try await output.prepare()
            if narration.timings {
                let elapsed = started.duration(to: .now) / .seconds(1)
                note(String(format: "model preparation: %.2fs", elapsed))
            }
            let terminal = narration.controls ? VoiceSayTerminal() : nil
            defer { terminal?.stop() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                if let terminal {
                    group.addTask {
                        await listenForPause(
                            terminal, output: output, announce: narration.announcePause
                        )
                    }
                }
                defer { group.cancelAll() }
                try await output.narrate(
                    blocks, streaming: narration.streaming,
                    onStart: {
                        if terminal?.start() == true, !quiet {
                            note("Space: pause/resume · Ctrl-C: stop")
                        }
                    },
                    onTiming: { timing in
                        guard narration.timings else { return }
                        let format =
                            "segment %d (%@): synthesis %.2fs · audio %.2fs · trimmed %.2fs"
                            + " · longest internal quiet %.2fs · queue wait %.2fs"
                            + " · playback idle total %.2fs"
                        note(
                            String(
                                format: format,
                                timing.index, timing.role.rawValue,
                                timing.generationSeconds, timing.audioSeconds,
                                timing.trimmedSeconds, timing.longestInternalSilenceSeconds,
                                timing.queueWaitSeconds, timing.playbackIdleSeconds
                            )
                        )
                    },
                    onSkipped: { index, reason in
                        note("skipped segment \(index) (\(reason.rawValue))")
                    }
                )
            }
        } catch {
            await output.unload()
            throw error
        }
        await output.unload()
    }

    private static func listenForPause(
        _ terminal: VoiceSayTerminal, output: MLXSpeechOutput, announce: Bool
    ) async {
        let feedback = announce ? await AppleSpeechOutput() : nil
        var announcement: Task<Void, Never>?
        for await _ in terminal.spaces {
            guard !Task.isCancelled else { break }
            announcement?.cancel()
            _ = await announcement?.result
            let paused = await output.togglePause()
            note(paused ? "Paused — Space to resume" : "Resumed")
            if paused, let feedback {
                announcement = Task {
                    _ = try? await feedback.speak("Paused", voiceIdentifier: nil)
                }
            }
        }
        announcement?.cancel()
        _ = await announcement?.result
        await feedback?.stopImmediately()
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
    func resolveInput() throws -> (blocks: [SpeechNarrationBlock], streaming: Bool) {
        let text = try Self.resolveText(words, file: file)
        let fromOperands = !words.isEmpty
        let blocks =
            fromOperands
            ? (text.isEmpty ? [] : [SpeechNarrationBlock(role: .narrator, text: text)])
            : VoiceSayDocument.blocks(from: text)
        guard !blocks.isEmpty else {
            throw ValidationError(
                "No speakable text remains. Pass text, use --file, or pipe it on stdin.")
        }
        return (blocks, fromOperands || stream)
    }

    static func resolveText(_ words: [String], file: String? = nil) throws -> String {
        if let file, file != "-" {
            let path = (file as NSString).expandingTildeInPath
            return try VoiceSayInput.readFile(path)
        }
        if !words.isEmpty {
            return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try VoiceSayInput.read(.standardInput)
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
