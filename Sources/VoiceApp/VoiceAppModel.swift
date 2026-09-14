import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import VoiceCore
import VoiceMLX
import VoicePlatform

@MainActor
@Observable
final class VoiceAppModel {
    static let customACPAgentSelectionID = "custom-acp-executable"

    enum CaptureDestination: String, CaseIterable, Identifiable {
        case dictation = "Focused app"
        case planning = "Planning agent"

        var id: Self { self }
    }

    enum PlanningBackend: String, CaseIterable, Identifiable {
        case onDevice = "Apple On-Device"
        case codex = "Codex"
        case acp = "ACP Agent"

        var id: Self { self }
    }

    enum DictationBackend: String, CaseIterable, Identifiable {
        case apple = "Apple Speech"
        case mlxSmall = "MLX · Qwen3 0.6B 8-bit"
        case mlxLarge = "MLX · Qwen3 1.7B 8-bit"
        case mlxGranite = "MLX · Granite 4.0 1B 5-bit · coding"
        case mlxCohere = "MLX · Cohere Transcribe 2B 8-bit · accuracy"
        case mlxParakeet = "MLX · Parakeet TDT 0.6B v3 · fast multilingual"

        var id: Self { self }

        var mlxModel: MLXSpeechModel? {
            switch self {
            case .apple:
                nil
            case .mlxSmall:
                .qwenSmall
            case .mlxLarge:
                .qwenLarge
            case .mlxGranite:
                .graniteCoding
            case .mlxCohere:
                .cohereAccuracy
            case .mlxParakeet:
                .parakeetFast
            }
        }

        var preferenceIdentifier: String {
            switch self {
            case .apple:
                "apple"
            case .mlxSmall:
                "qwen3-asr-0.6b-8bit"
            case .mlxLarge:
                "qwen3-asr-1.7b-8bit"
            case .mlxGranite:
                "granite-4.0-1b-speech-5bit"
            case .mlxCohere:
                "cohere-transcribe-03-2026-8bit"
            case .mlxParakeet:
                // Keep the original stable identifier so existing selections
                // migrate from the retired v2 checkpoint without user action.
                "parakeet-tdt-0.6b-v2"
            }
        }

        init?(preferenceIdentifier: String) {
            guard
                let backend = Self.allCases.first(where: {
                    $0.preferenceIdentifier == preferenceIdentifier
                })
            else {
                return nil
            }
            self = backend
        }
    }

    enum MLXBenchmarkPhase: Equatable {
        case idle
        case starting
        case recording
        case comparing(model: String, index: Int, total: Int)
        case cancelling
        case finished
    }

    enum MLXIdleUnloadDelay: Int, CaseIterable, Identifiable {
        case never = 0
        case fiveMinutes = 5
        case fifteenMinutes = 15
        case thirtyMinutes = 30

        var id: Self { self }

        var label: String {
            switch self {
            case .never:
                "Keep loaded"
            case .fiveMinutes:
                "After 5 minutes"
            case .fifteenMinutes:
                "After 15 minutes"
            case .thirtyMinutes:
                "After 30 minutes"
            }
        }
    }

    enum SpeechBackend: String, CaseIterable, Identifiable {
        case system = "System (Apple)"
        case qwenSmall = "MLX · Qwen3-TTS 0.6B (fast)"
        case qwenLarge = "MLX · Qwen3-TTS 1.7B (quality)"

        var id: Self { self }

        var mlxTier: MLXSpeechModelTier? {
            switch self {
            case .system:
                nil
            case .qwenSmall:
                .small
            case .qwenLarge:
                .large
            }
        }

        var preferenceIdentifier: String {
            switch self {
            case .system:
                "system"
            case .qwenSmall:
                "qwen3-tts-0.6b-8bit"
            case .qwenLarge:
                "qwen3-tts-1.7b-8bit"
            }
        }

        init?(preferenceIdentifier: String) {
            guard
                let backend = Self.allCases.first(where: {
                    $0.preferenceIdentifier == preferenceIdentifier
                })
            else {
                return nil
            }
            self = backend
        }
    }

    enum MLXVoiceMode: String, CaseIterable, Identifiable {
        case preset = "Preset voice"
        case designed = "Describe a voice"
        case cloned = "Clone from audio"

        var id: Self { self }

        var preferenceIdentifier: String {
            switch self {
            case .preset:
                "preset"
            case .designed:
                "designed"
            case .cloned:
                "cloned"
            }
        }

        init?(preferenceIdentifier: String) {
            guard
                let mode = Self.allCases.first(where: {
                    $0.preferenceIdentifier == preferenceIdentifier
                })
            else {
                return nil
            }
            self = mode
        }
    }

    var presentation: VoicePresentation = .idle
    var destination: CaptureDestination = .dictation
    var planningBackend: PlanningBackend = .onDevice
    var selectedDictationBackend: DictationBackend = .apple
    var activeDictationBackend: DictationBackend = .apple
    var isDictationModelPreparing = false
    var dictationModelStatus = "Apple Speech ready"
    var dictationModelError: String?
    var lastMLXMetrics: MLXTranscriptionMetrics?
    var downloadedMLXBenchmarkModels: [MLXSpeechModel] = []
    var mlxBenchmarkResults: [MLXBenchmarkResult] = []
    var mlxBenchmarkPhase: MLXBenchmarkPhase = .idle
    var mlxBenchmarkError: String?
    var isMLXBenchmarkCacheRefreshing = false
    var failedDictationBackend: DictationBackend?
    var projectURL: URL?
    var codexExecutableURL = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    var acpExecutableURL: URL?
    var acpArgumentsText = ""
    var discoveredACPAgents: [ACPAgentLaunchChoice] = []
    var acpAgentSelectionID = VoiceAppModel.customACPAgentSelectionID
    var isDiscoveringACPAgents = false
    var selectedVoiceIdentifier: String?
    var selectedSpeechBackend: SpeechBackend = .system
    var activeSpeechBackend: SpeechBackend = .system
    var isSpeechModelPreparing = false
    var speechModelStatus = "System voice ready"
    var speechModelError: String?
    var selectedMLXSpeechVoice: MLXSpeechVoice = .ryan
    var mlxVoiceMode: MLXVoiceMode = .preset
    var mlxVoiceStyleText = ""
    var mlxVoiceDescriptionText = ""
    var mlxCloneReferenceURL: URL?
    var mlxCloneTranscriptText = ""
    var isAgentConnected = false
    var isAgentConnecting = false
    var isProjectSelectionLocked: Bool { isAgentConnected || isAgentConnecting }
    static let projectSelectionLockedHelp =
        "Disconnect the planning agent before changing projects."
    var agentConfigurationOptions: [AgentSessionConfigurationOption] = []
    var isAgentConfigurationUpdating = false
    var agentConfigurationError: String?
    var isHotkeyAvailable = false
    var lastHotkeyDetection = "Never"
    var isHotkeyHeld = false
    var microphoneGranted = VoicePermissions.hasMicrophoneAccess
    var defaultAudioInputName = "System default input"
    var defaultAudioInputIsBluetooth = false
    var accessibilityGranted = VoicePermissions.hasAccessibilityAccess(prompt: false)
    var inputMonitoringGranted = VoicePermissions.hasInputMonitoringAccess
    var lexiconCount = 0
    var compatibilityInsertionEnabled = true {
        didSet {
            injector.setUnicodeEventFallbackEnabled(compatibilityInsertionEnabled)
            preferences.setCompatibilityInsertionEnabled(compatibilityInsertionEnabled)
        }
    }
    var manualSpeechVocabularyText = ""
    var skipSilentShortMLXAudio = false {
        didSet {
            preferences.setSkipSilentShortMLXAudio(skipSilentShortMLXAudio)
        }
    }
    var mlxIdleUnloadDelay: MLXIdleUnloadDelay = .never
    var historyEnabled = false {
        didSet {
            historyEventID &+= 1
            let enabled = historyEnabled
            let eventID = historyEventID
            Task { @concurrent [session] in
                await session.setHistoryEnabled(enabled, eventID: eventID)
            }
        }
    }
    var lastExportableText = ""
    var lastRawTranscript = ""
    var lastCleanedTranscript = ""
    var lastCleanupSource: CleanedPrompt.Source?

    private let overlay = StatusPanelController()
    @ObservationIgnored
    private lazy var historyStore = EncryptedHistoryStore(
        storageURL: VoiceAppModel.historyStorageURL
    )
    @ObservationIgnored
    private lazy var cleaner = AppleFoundationModelCleaner()
    @ObservationIgnored
    private lazy var injector = AccessibilityTargetInjector()
    @ObservationIgnored
    private lazy var mlxBenchmark = MLXModelBenchmark()
    private let preferences: VoicePreferences
    private let systemSpeechOutput = AppleSpeechOutput()
    @ObservationIgnored
    private lazy var speechRouter = SwitchableSpeechOutput(
        engine: systemSpeechOutput
    )
    @ObservationIgnored
    private var mlxSpeechOutput: MLXSpeechOutput?
    @ObservationIgnored
    private var speechSelectionID: UUID?
    @ObservationIgnored
    private var activeSpeechCheckpoint: MLXSpeechCheckpoint?
    @ObservationIgnored
    private lazy var session = VoiceSession(
        recognizer: AppleSpeechRecognizer(),
        cleaner: cleaner,
        injector: injector,
        speechOutput: speechRouter,
        historyStore: historyStore
    ) { [weak self] presentation in
        Task { @MainActor [weak self] in
            self?.apply(presentation)
        }
    }
    @ObservationIgnored
    private lazy var hotkey = GlobalHotkeyMonitor(
        onPress: { [weak self] eventID, mode in
            Task { @MainActor [weak self] in
                self?.hotkeyPressed(eventID: eventID, mode: mode)
            }
        },
        onRelease: { [weak self] eventID in
            Task { @MainActor [weak self] in
                self?.hotkeyReleased(eventID: eventID)
            }
        }
    )
    @ObservationIgnored
    private var agentTransport: (any AgentTransport)?
    @ObservationIgnored
    private var agentConfigurationSelectionID: UUID?
    @ObservationIgnored
    private var historyEventID: UInt64 = 0
    @ObservationIgnored
    private var lastPresentationRevision: UInt64 = 0
    @ObservationIgnored
    private var lastObservedHotkeyEventID: UInt64 = 0
    @ObservationIgnored
    private var orderedSessionDelivery: Task<Void, Never>?
    @ObservationIgnored
    private var contextualStrings: [String] = []
    @ObservationIgnored
    private var projectContextualStrings: [String] = []
    @ObservationIgnored
    private var dictationSelectionID: UUID?
    @ObservationIgnored
    private var dictationSelectionTask: Task<Void, Never>?
    @ObservationIgnored
    private var preparingDictationCandidate: (any SpeechRecognizing)?
    @ObservationIgnored
    private var pendingDictationCandidate: PendingDictationCandidate?
    @ObservationIgnored
    private var isDictationModelActivating = false
    @ObservationIgnored
    private var mlxBenchmarkTask: Task<Void, Never>?
    @ObservationIgnored
    private var mlxBenchmarkModels: [MLXSpeechModel] = []
    @ObservationIgnored
    private var mlxBenchmarkRunID: UUID?
    @ObservationIgnored
    private var mlxBenchmarkReservationID: UUID?
    @ObservationIgnored
    private var mlxIdleUnloadTask: Task<Void, Never>?
    @ObservationIgnored
    private var planningWindowReveal = WindowReveal()
    @ObservationIgnored
    private var settingsWindowReveal = WindowReveal()

    /// A menu command asks for a window before SwiftUI has created it, so the
    /// request is held until the scene reports its `NSWindow`.
    @MainActor
    private struct WindowReveal {
        weak var window: NSWindow?
        var isPending = false

        mutating func request() {
            isPending = !Self.reveal(window)
        }

        mutating func register(_ window: NSWindow?) {
            self.window = window
            if isPending, Self.reveal(window) {
                isPending = false
            }
        }

        /// `.moveToActiveSpace` is applied for one ordering pass only. Leaving
        /// it installed would permanently change how the user's Settings and
        /// Planning windows participate in Spaces. Only the reveal that
        /// inserted the flag removes it, so a second reveal arriving before the
        /// first restore cannot capture the flag as the window's original
        /// behavior and make it stick.
        private static func reveal(_ window: NSWindow?) -> Bool {
            guard let window else { return false }
            let insertedMoveToActiveSpace =
                !window.collectionBehavior.contains(.moveToActiveSpace)
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            guard insertedMoveToActiveSpace else { return true }
            Task { @MainActor [weak window] in
                await Task.yield()
                window?.collectionBehavior.remove(.moveToActiveSpace)
            }
            return true
        }
    }

    private struct PendingDictationCandidate {
        let selectionID: UUID
        let backend: DictationBackend
        let recognizer: any SpeechRecognizing
    }
    init(preferences: VoicePreferences = VoicePreferences()) {
        self.preferences = preferences
        // @Observable rewrites this into a computed property, so unlike a plain
        // stored property the assignment does run didSet: the injector is
        // configured and the value is written back to preferences here.
        compatibilityInsertionEnabled = preferences.compatibilityInsertionEnabled
        manualSpeechVocabularyText = preferences.manualSpeechVocabulary
        contextualStrings = ManualSpeechVocabulary.terms(
            from: manualSpeechVocabularyText
        )
        skipSilentShortMLXAudio = preferences.skipSilentShortMLXAudio
        mlxIdleUnloadDelay =
            MLXIdleUnloadDelay(rawValue: preferences.mlxIdleUnloadMinutes) ?? .never
        let restoredBackend =
            preferences.dictationBackendIdentifier.flatMap {
                DictationBackend(preferenceIdentifier: $0)
            } ?? .apple
        selectedDictationBackend = restoredBackend
        if restoredBackend != .apple {
            dictationModelStatus = "Restoring \(restoredBackend.rawValue)…"
        }
        let restoredSpeechBackend =
            preferences.speechBackendIdentifier.flatMap {
                SpeechBackend(preferenceIdentifier: $0)
            } ?? .system
        selectedMLXSpeechVoice =
            preferences.mlxSpeechVoiceIdentifier.flatMap {
                MLXSpeechVoice(rawValue: $0)
            } ?? .ryan
        mlxVoiceMode =
            preferences.mlxVoiceModeIdentifier.flatMap {
                MLXVoiceMode(preferenceIdentifier: $0)
            } ?? .preset
        mlxVoiceStyleText = preferences.mlxVoiceStyle ?? ""
        mlxVoiceDescriptionText = preferences.mlxVoiceDescription ?? ""
        mlxCloneReferenceURL = preferences.mlxCloneReferencePath.map {
            URL(fileURLWithPath: $0)
        }
        mlxCloneTranscriptText = preferences.mlxCloneTranscript ?? ""
        if restoredSpeechBackend != .system {
            speechModelStatus = "Restoring \(restoredSpeechBackend.rawValue)…"
        }
        // The model lives for the process lifetime, so these loops run until
        // the process exits; the weak captures keep them from retaining it.
        Task { @MainActor [weak self] in
            let activations = NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification
            )
            for await _ in activations {
                guard let self else { return }
                refreshPermissionsAndHotkey()
            }
        }
        Task { @MainActor [weak self] in
            let sleeps = NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.willSleepNotification
            )
            for await _ in sleeps {
                guard let self else { return }
                unloadMLXResourcesForSleep()
            }
        }
        DefaultAudioInput.observeChanges { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDefaultAudioInput()
            }
        }
        refreshACPAgents()
        Task { @MainActor [weak self] in
            guard let self else { return }
            refreshPermissionsAndHotkey()
            await session.setContextualStrings(contextualStrings)
            await session.prewarm()
            if restoredBackend != .apple,
                selectedDictationBackend == restoredBackend,
                preferences.dictationBackendIdentifier
                    == restoredBackend.preferenceIdentifier,
                dictationSelectionID == nil
            {
                selectDictationBackend(restoredBackend)
            }
            if restoredSpeechBackend != .system, speechSelectionID == nil {
                selectSpeechBackend(restoredSpeechBackend)
            }
            await cleaner.prewarm()
        }
    }

    var menuStatusMessage: String {
        guard presentation.phase == .idle, !isHotkeyAvailable else {
            return presentation.message
        }
        return inputMonitoringGranted
            ? "Hotkey unavailable · quit and reopen Voice"
            : "Hotkey unavailable · grant Input Monitoring"
    }

    func requestPlanningWindowReveal() {
        planningWindowReveal.request()
    }

    func requestSettingsWindowReveal() {
        settingsWindowReveal.request()
    }

    func registerPlanningWindow(_ window: NSWindow?) {
        planningWindowReveal.register(window)
    }

    func registerSettingsWindow(_ window: NSWindow?) {
        settingsWindowReveal.register(window)
    }

    var isSpeakingPlanningResponse: Bool {
        isAgentConnected
            && presentation.isConnectedPlanning
            && presentation.phase == .speaking
    }

    var eventTapDescription: String {
        guard !isHotkeyAvailable else { return "Ready" }
        if inputMonitoringGranted {
            return "Unavailable · relaunch Voice"
        }
        return "Input Monitoring required"
    }

    var defaultAudioInputDetail: String {
        defaultAudioInputIsBluetooth
            ? "\(defaultAudioInputName) · Bluetooth"
            : defaultAudioInputName
    }

    var hotkeyDetectionDescription: String {
        guard lastHotkeyDetection != "Never" else { return lastHotkeyDetection }
        return "\(lastHotkeyDetection) · \(isHotkeyHeld ? "held" : "released")"
    }

    var dictationBackendDescription: String {
        guard let model = selectedDictationBackend.mlxModel else {
            return "Incremental Apple Speech with project vocabulary. Audio stays on this Mac."
        }
        return
            "\(model.detail) First selection downloads \(model.approximateDownload) from Hugging Face; microphone audio never leaves this Mac."
    }

    var mlxMetricsDescription: String? {
        guard let metrics = lastMLXMetrics else { return nil }
        return String(
            format:
                "Last MLX turn · %@: %.2fs inference for %.1fs audio · %.2fx realtime · %.2f GB reported peak",
            metrics.model.displayName,
            metrics.inferenceDuration,
            metrics.audioDuration,
            metrics.realTimeFactor,
            metrics.peakMemoryGB
        )
    }

    var isMLXBenchmarkActive: Bool {
        switch mlxBenchmarkPhase {
        case .starting, .recording, .comparing, .cancelling:
            true
        case .idle, .finished:
            false
        }
    }

    var canStartMLXBenchmark: Bool {
        !isMLXBenchmarkActive
            && !isMLXBenchmarkCacheRefreshing
            && activeDictationBackend == .apple
            && !isDictationModelPreparing
            && !isHotkeyHeld
            && [.idle, .failed].contains(presentation.phase)
            && downloadedMLXBenchmarkModels.count >= 2
    }

    var mlxBenchmarkStatus: String {
        switch mlxBenchmarkPhase {
        case .idle:
            if isMLXBenchmarkCacheRefreshing {
                return "Checking downloaded models…"
            }
            if activeDictationBackend != .apple {
                return "Switch to Apple Speech to compare cached MLX models."
            }
            if downloadedMLXBenchmarkModels.count < 2 {
                return "Download at least two MLX models by selecting each one first."
            }
            return "Ready to compare \(downloadedMLXBenchmarkModels.count) cached models."
        case .starting:
            return "Starting memory-only comparison recording…"
        case .recording:
            return "Recording · speak once, then stop to run every cached model."
        case .comparing(let model, let index, let total):
            return "Comparing \(index) of \(total) · \(model)"
        case .cancelling:
            return "Cancelling after the current model pass, then releasing audio…"
        case .finished:
            return "Comparison finished · audio released from the benchmark."
        }
    }

    var lastCleanupSourceDescription: String {
        switch lastCleanupSource {
        case .deterministic:
            "Deterministic"
        case .foundationModels:
            "Apple Foundation Models"
        case nil:
            "Not available"
        }
    }

    var hasLastTurnDiagnostics: Bool {
        !lastRawTranscript.isEmpty || !lastCleanedTranscript.isEmpty
    }

    var lastTurnDiagnosticsText: String {
        """
        Raw ASR:
        \(lastRawTranscript.isEmpty ? "(not available)" : lastRawTranscript)

        Cleanup: \(lastCleanupSourceDescription)

        Sent to target:
        \(lastCleanedTranscript.isEmpty ? "(not available)" : lastCleanedTranscript)
        """
    }

    var menuBarSymbol: String {
        if isMLXBenchmarkActive {
            return mlxBenchmarkPhase == .recording
                ? "waveform.circle.fill" : "ellipsis.circle"
        }
        return switch presentation.phase {
        case .listening:
            "waveform.circle.fill"
        case .cleaning, .finalizing, .inserting, .planning:
            "ellipsis.circle"
        case .speaking:
            "speaker.wave.2.circle.fill"
        case .failed:
            "exclamationmark.circle"
        default:
            if !isHotkeyAvailable {
                "exclamationmark.triangle.fill"
            } else {
                isAgentConnected ? "waveform.badge.plus" : "waveform"
            }
        }
    }

    func requestPermissions() {
        _ = VoicePermissions.requestInputMonitoringAccess()
        _ = VoicePermissions.hasAccessibilityAccess(prompt: true)
        refreshPermissionsAndHotkey()
        Task { @concurrent [weak self] in
            let granted = await VoicePermissions.requestMicrophoneAccess()
            await MainActor.run {
                self?.microphoneGranted = granted
            }
        }
    }

    func applyManualSpeechVocabulary() {
        preferences.setManualSpeechVocabulary(manualSpeechVocabularyText)
        refreshContextualStrings()
    }

    func setMLXIdleUnloadDelay(_ delay: MLXIdleUnloadDelay) {
        mlxIdleUnloadDelay = delay
        preferences.setMLXIdleUnloadMinutes(delay.rawValue)
        scheduleMLXIdleUnload()
    }

    func copyLastTurnDiagnostics() {
        guard hasLastTurnDiagnostics else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(lastTurnDiagnosticsText, forType: .string)
    }

    func clearLastTurnDiagnostics() {
        lastRawTranscript = ""
        lastCleanedTranscript = ""
        lastCleanupSource = nil
    }

    func refreshPermissionsAndHotkey() {
        microphoneGranted = VoicePermissions.hasMicrophoneAccess
        accessibilityGranted = VoicePermissions.hasAccessibilityAccess(prompt: false)
        inputMonitoringGranted = VoicePermissions.hasInputMonitoringAccess
        refreshDefaultAudioInput()
        guard inputMonitoringGranted else {
            hotkey.stop()
            isHotkeyAvailable = false
            return
        }
        // start() tears down and rebuilds the tap, synthesizing a release that
        // would end a dictation in progress — this refresh runs on every app
        // activation, so leave a working tap alone.
        if !hotkey.isRunning {
            isHotkeyAvailable = hotkey.start()
        }
    }

    func refreshDefaultAudioInput() {
        let input = DefaultAudioInput.current()
        defaultAudioInputName = input?.name ?? "No system input device"
        defaultAudioInputIsBluetooth = input?.isBluetooth ?? false
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose the project used for vocabulary and planning"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectURL = url
        rebuildLexicon(for: url)
    }

    func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Codex executable"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        codexExecutableURL = url
    }

    func chooseACPExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose an ACP agent executable"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let replacingDiscoveredChoice =
            acpAgentSelectionID
            != Self.customACPAgentSelectionID
        acpExecutableURL = url
        acpAgentSelectionID = Self.customACPAgentSelectionID
        if replacingDiscoveredChoice {
            acpArgumentsText = ""
        }
    }

    func selectACPAgent(_ selectionID: String) {
        guard let choice = discoveredACPAgents.first(where: { $0.id == selectionID }) else {
            return
        }
        applyACPAgentChoice(choice)
    }

    func refreshACPAgents() {
        guard !isDiscoveringACPAgents else { return }
        isDiscoveringACPAgents = true
        Task { @concurrent [weak self] in
            let choices = ZedACPAgentDiscovery().discover()
            await MainActor.run { [weak self] in
                self?.applyDiscoveredACPAgents(choices)
            }
        }
    }

    func connectPlanning() {
        guard !isAgentConnecting, !isAgentConnected else { return }
        guard !isMLXBenchmarkActive else {
            presentFailure("Finish or cancel the MLX comparison first.")
            return
        }
        guard let projectURL else {
            presentFailure("Choose a project first.")
            return
        }
        if planningBackend == .acp, acpExecutableURL == nil {
            presentFailure("Choose an ACP agent executable first.")
            return
        }
        isAgentConnecting = true
        agentConfigurationOptions = []
        agentConfigurationError = nil
        isAgentConfigurationUpdating = false
        agentConfigurationSelectionID = nil
        let transport: any AgentTransport =
            switch planningBackend {
            case .onDevice:
                LocalFoundationModelTransport()
            case .codex:
                CodexAppServerTransport()
            case .acp:
                ACPAgentTransport()
            }
        agentTransport = transport
        let configuration = AgentConfiguration(
            executableURL: planningExecutableURL,
            projectURL: projectURL,
            arguments: planningBackend == .acp ? acpArguments : [],
            sessionConfigurationValues: planningBackend == .acp
                ? preferredACPConfigurationValues : [:]
        )
        Task { @concurrent [weak self, session] in
            do {
                await session.setPlanningDisconnectHandler { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.agentTransport = nil
                        self.isAgentConnected = false
                        self.agentConfigurationOptions = []
                        self.isAgentConfigurationUpdating = false
                        self.agentConfigurationSelectionID = nil
                        self.destination = .dictation
                    }
                }
                await session.setPlanningConfigurationHandler { [weak self] options in
                    Task { @MainActor [weak self] in
                        self?.agentConfigurationOptions = options
                    }
                }
                try await session.connectPlanning(
                    transport: transport,
                    configuration: configuration
                )
                let configurationOptions =
                    await session
                    .currentPlanningConfigurationOptions()
                await MainActor.run {
                    self?.isAgentConnected = true
                    self?.isAgentConnecting = false
                    self?.agentConfigurationOptions = configurationOptions
                    self?.destination = .planning
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.agentTransport = nil
                    self?.isAgentConnected = false
                    self?.isAgentConnecting = false
                    self?.agentConfigurationOptions = []
                    self?.isAgentConfigurationUpdating = false
                    self?.agentConfigurationSelectionID = nil
                }
            } catch {
                await MainActor.run {
                    self?.agentTransport = nil
                    self?.isAgentConnected = false
                    self?.isAgentConnecting = false
                    self?.agentConfigurationOptions = []
                    self?.isAgentConfigurationUpdating = false
                    self?.agentConfigurationSelectionID = nil
                    self?.presentFailure(error.localizedDescription)
                }
            }
        }
    }

    func selectAgentConfiguration(
        optionID: String,
        value: AgentSessionConfigurationValue
    ) {
        guard isAgentConnected, !isAgentConfigurationUpdating,
            let index = agentConfigurationOptions.firstIndex(where: { $0.id == optionID }),
            agentConfigurationOptions[index].accepts(value),
            agentConfigurationOptions[index].currentValue != value
        else {
            return
        }

        let previousOptions = agentConfigurationOptions
        agentConfigurationOptions[index] = agentConfigurationOptions[index]
            .replacingCurrentValue(value)
        isAgentConfigurationUpdating = true
        agentConfigurationError = nil
        let selectionID = UUID()
        agentConfigurationSelectionID = selectionID
        let agentIdentifier = acpPreferenceAgentIdentifier
        Task { @concurrent [weak self, session] in
            do {
                let options = try await session.setPlanningConfiguration(
                    id: optionID,
                    value: value
                )
                await MainActor.run {
                    guard let self,
                        self.agentConfigurationSelectionID == selectionID
                    else {
                        return
                    }
                    self.agentConfigurationOptions = options
                    self.isAgentConfigurationUpdating = false
                    self.agentConfigurationSelectionID = nil
                    if case .string(let selectedValue) =
                        options
                        .first(where: { $0.id == optionID })?.currentValue
                    {
                        self.preferences.setACPConfigurationSelection(
                            agentIdentifier: agentIdentifier,
                            configID: optionID,
                            value: selectedValue
                        )
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self,
                        self.agentConfigurationSelectionID == selectionID
                    else {
                        return
                    }
                    self.isAgentConfigurationUpdating = false
                    self.agentConfigurationSelectionID = nil
                }
            } catch {
                await MainActor.run {
                    guard let self,
                        self.agentConfigurationSelectionID == selectionID
                    else {
                        return
                    }
                    self.agentConfigurationOptions = previousOptions
                    self.isAgentConfigurationUpdating = false
                    self.agentConfigurationSelectionID = nil
                    self.agentConfigurationError = error.localizedDescription
                    self.presentFailure(error.localizedDescription)
                }
            }
        }
    }

    var planningBackendLabel: String {
        planningBackend.rawValue
    }

    var planningPrivacyDescription: String {
        switch planningBackend {
        case .onDevice:
            "Conversation and speech stay on this Mac. The system model has no project-file or network access."
        case .codex:
            "Audio and volatile speech stay local. Codex receives finalized text and a read-only project working directory; it may send project context through its configured model/account."
        case .acp:
            "Audio and volatile speech stay local. The ACP process receives finalized text and the project working directory. Voice denies permissions and supplies no MCP servers, but the agent must enforce its own sandbox."
        }
    }

    private var planningExecutableURL: URL {
        switch planningBackend {
        case .onDevice:
            URL(fileURLWithPath: "/usr/bin/true")
        case .codex:
            codexExecutableURL
        case .acp:
            acpExecutableURL ?? URL(fileURLWithPath: "/usr/bin/false")
        }
    }

    private var acpArguments: [String] {
        acpArgumentsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var acpPreferenceAgentIdentifier: String {
        guard acpAgentSelectionID == Self.customACPAgentSelectionID else {
            return acpAgentSelectionID
        }
        let executable = acpExecutableURL?.standardizedFileURL.path ?? "unselected"
        return "custom:\(executable):\(acpArguments.joined(separator: "\u{1F}"))"
    }

    private var preferredACPConfigurationValues: [String: AgentSessionConfigurationValue] {
        preferences.acpSessionConfigurationSelections(
            agentIdentifier: acpPreferenceAgentIdentifier
        ).mapValues(AgentSessionConfigurationValue.string)
    }

    private func applyDiscoveredACPAgents(_ choices: [ACPAgentLaunchChoice]) {
        discoveredACPAgents = choices
        isDiscoveringACPAgents = false

        if let selected = choices.first(where: { $0.id == acpAgentSelectionID }) {
            applyACPAgentChoice(selected)
            return
        }
        if let executableURL = acpExecutableURL,
            let matching = choices.first(where: {
                $0.executableURL.standardizedFileURL == executableURL.standardizedFileURL
                    && $0.arguments == acpArguments
            })
        {
            applyACPAgentChoice(matching)
            return
        }
        guard acpExecutableURL == nil, let first = choices.first else {
            acpAgentSelectionID = Self.customACPAgentSelectionID
            return
        }
        applyACPAgentChoice(first)
    }

    private func applyACPAgentChoice(_ choice: ACPAgentLaunchChoice) {
        acpAgentSelectionID = choice.id
        acpExecutableURL = choice.executableURL
        acpArgumentsText = choice.arguments.joined(separator: "\n")
    }

    func disconnectPlanning() {
        Task { @concurrent [weak self, session] in
            await session.disconnectPlanning()
            await MainActor.run {
                self?.agentTransport = nil
                self?.isAgentConnected = false
                self?.agentConfigurationOptions = []
                self?.isAgentConfigurationUpdating = false
                self?.agentConfigurationSelectionID = nil
                self?.destination = .dictation
            }
        }
    }

    func cancel() {
        Task { @concurrent [session] in
            await session.cancel()
        }
    }

    func stopSpeaking() {
        Task { @concurrent [session] in
            await session.stopSpeaking()
        }
    }

    func quit() {
        hotkey.stop()
        cancelDictationModelPreparation()
        let benchmarkOperation = mlxBenchmarkTask
        benchmarkOperation?.cancel()
        let benchmark = mlxBenchmark
        let reservationID = mlxBenchmarkReservationID
        Task { @concurrent [session] in
            await benchmark.cancel()
            _ = await benchmarkOperation?.result
            if let reservationID {
                await session.releaseExternalCapture(reservationID: reservationID)
            }
            await session.cancel()
            await session.disconnectPlanning()
            await MainActor.run {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func selectVoice(_ identifier: String?) {
        selectedVoiceIdentifier = identifier
        enqueueOrderedSessionDelivery { session in
            await session.setVoiceIdentifier(identifier)
        }
    }

    func selectSpeechBackend(_ backend: SpeechBackend) {
        guard !isSpeechModelPreparing else {
            selectedSpeechBackend = activeSpeechBackend
            return
        }
        selectedSpeechBackend = backend

        guard let tier = backend.mlxTier else {
            guard backend != activeSpeechBackend else {
                preferences.setSpeechBackendIdentifier(backend.preferenceIdentifier)
                return
            }
            let selectionID = UUID()
            speechSelectionID = selectionID
            isSpeechModelPreparing = true
            speechModelError = nil
            speechModelStatus = "Activating the system voice…"
            let previous = mlxSpeechOutput
            mlxSpeechOutput = nil
            activeSpeechCheckpoint = nil
            let router = speechRouter
            let system = systemSpeechOutput
            Task { @concurrent [weak self] in
                await router.setEngine(system)
                await previous?.unload()
                await MainActor.run {
                    guard let self, self.speechSelectionID == selectionID else { return }
                    self.finishSpeechSelection(backend: backend, status: "System voice ready")
                }
            }
            return
        }

        guard let configuration = validatedMLXVoiceConfiguration() else {
            selectedSpeechBackend = activeSpeechBackend
            return
        }
        let checkpoint = MLXSpeechCheckpoint.checkpoint(
            tier: tier,
            configuration: configuration
        )
        if backend == activeSpeechBackend, checkpoint == activeSpeechCheckpoint {
            preferences.setSpeechBackendIdentifier(backend.preferenceIdentifier)
            return
        }
        activateMLXSpeech(
            backend: backend,
            checkpoint: checkpoint,
            configuration: configuration
        )
    }

    /// Applies edits to the MLX voice fields (mode, preset, style, description,
    /// clone clip, transcript). Switches checkpoints when the mode requires a
    /// different Qwen3-TTS variant; otherwise updates the running engine.
    func applyMLXVoiceSettings() {
        persistMLXVoiceSettings()
        guard let tier = selectedSpeechBackend.mlxTier else { return }
        guard !isSpeechModelPreparing else { return }
        guard let configuration = validatedMLXVoiceConfiguration() else { return }
        let checkpoint = MLXSpeechCheckpoint.checkpoint(
            tier: tier,
            configuration: configuration
        )
        if checkpoint == activeSpeechCheckpoint, let engine = mlxSpeechOutput {
            speechModelError = nil
            speechModelStatus = "\(selectedSpeechBackend.rawValue) ready"
            Task { @concurrent in
                await engine.setConfiguration(configuration)
            }
            return
        }
        activateMLXSpeech(
            backend: selectedSpeechBackend,
            checkpoint: checkpoint,
            configuration: configuration
        )
    }

    func selectMLXVoiceMode(_ mode: MLXVoiceMode) {
        mlxVoiceMode = mode
        applyMLXVoiceSettings()
    }

    func selectMLXSpeechVoice(_ voice: MLXSpeechVoice) {
        selectedMLXSpeechVoice = voice
        applyMLXVoiceSettings()
    }

    func chooseMLXCloneReferenceClip() {
        let panel = NSOpenPanel()
        panel.title = "Choose a short, clean reference clip (about 3–10 seconds)"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mlxCloneReferenceURL = url
        applyMLXVoiceSettings()
    }

    /// Builds the voice configuration for the current mode, or presents why it
    /// is incomplete and returns nil.
    private func validatedMLXVoiceConfiguration() -> MLXVoiceConfiguration? {
        switch mlxVoiceMode {
        case .preset:
            return .preset(selectedMLXSpeechVoice, style: mlxVoiceStyleText)
        case .designed:
            let description =
                mlxVoiceDescriptionText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else {
                speechModelStatus = "Describe the voice to activate it"
                return nil
            }
            return .designed(description: description)
        case .cloned:
            guard let mlxCloneReferenceURL else {
                speechModelStatus = "Choose a reference clip to clone"
                return nil
            }
            let transcript =
                mlxCloneTranscriptText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                speechModelStatus = "Enter the words spoken in the reference clip"
                return nil
            }
            return .cloned(
                referenceAudioURL: mlxCloneReferenceURL,
                transcript: transcript,
                style: mlxVoiceStyleText
            )
        }
    }

    private func activateMLXSpeech(
        backend: SpeechBackend,
        checkpoint: MLXSpeechCheckpoint,
        configuration: MLXVoiceConfiguration
    ) {
        let selectionID = UUID()
        speechSelectionID = selectionID
        isSpeechModelPreparing = true
        speechModelError = nil
        speechModelStatus = "Preparing \(checkpoint.displayName)…"
        let engine = MLXSpeechOutput(
            checkpoint: checkpoint,
            configuration: configuration,
            onPreparation: { [weak self] stage in
                Task { @MainActor [weak self] in
                    self?.applyMLXSpeechPreparation(
                        stage,
                        checkpoint: checkpoint,
                        selectionID: selectionID
                    )
                }
            }
        )
        let previous = mlxSpeechOutput
        let router = speechRouter
        Task { @concurrent [weak self] in
            do {
                try await engine.prepare()
                let accepted = await MainActor.run { () -> Bool in
                    guard let self, self.speechSelectionID == selectionID else { return false }
                    self.mlxSpeechOutput = engine
                    return true
                }
                guard accepted else {
                    await engine.unload()
                    return
                }
                await router.setEngine(engine)
                await previous?.unload()
                await MainActor.run {
                    guard let self, self.speechSelectionID == selectionID else { return }
                    self.activeSpeechCheckpoint = checkpoint
                    self.finishSpeechSelection(
                        backend: backend,
                        status: "\(backend.rawValue) ready"
                    )
                }
            } catch {
                await engine.unload()
                await MainActor.run {
                    guard let self, self.speechSelectionID == selectionID else { return }
                    self.speechSelectionID = nil
                    self.isSpeechModelPreparing = false
                    self.selectedSpeechBackend = self.activeSpeechBackend
                    self.speechModelStatus =
                        "\(self.activeSpeechBackend.rawValue) remains active"
                    self.speechModelError = error.localizedDescription
                    self.presentFailure(error.localizedDescription)
                }
            }
        }
    }

    private func persistMLXVoiceSettings() {
        preferences.setMLXSpeechVoiceIdentifier(selectedMLXSpeechVoice.rawValue)
        preferences.setMLXVoiceModeIdentifier(mlxVoiceMode.preferenceIdentifier)
        preferences.setMLXVoiceStyle(mlxVoiceStyleText)
        preferences.setMLXVoiceDescription(mlxVoiceDescriptionText)
        preferences.setMLXCloneReferencePath(mlxCloneReferenceURL?.path)
        preferences.setMLXCloneTranscript(mlxCloneTranscriptText)
    }

    private func finishSpeechSelection(backend: SpeechBackend, status: String) {
        speechSelectionID = nil
        isSpeechModelPreparing = false
        activeSpeechBackend = backend
        selectedSpeechBackend = backend
        speechModelStatus = status
        preferences.setSpeechBackendIdentifier(backend.preferenceIdentifier)
    }

    private func applyMLXSpeechPreparation(
        _ stage: MLXModelPreparationStage,
        checkpoint: MLXSpeechCheckpoint,
        selectionID: UUID
    ) {
        guard speechSelectionID == selectionID, isSpeechModelPreparing else { return }
        switch stage {
        case .downloading(let fraction):
            speechModelStatus = String(
                format: "Downloading %@ · %.0f%%",
                checkpoint.displayName,
                fraction * 100
            )
        case .loading:
            speechModelStatus = "Loading \(checkpoint.displayName) into memory…"
        case .ready:
            speechModelStatus = "Activating \(checkpoint.displayName)…"
        }
    }

    func refreshMLXBenchmarkModels() {
        guard !isMLXBenchmarkActive, !isMLXBenchmarkCacheRefreshing else { return }
        isMLXBenchmarkCacheRefreshing = true
        let benchmark = mlxBenchmark
        Task { @concurrent [weak self] in
            let models = await benchmark.downloadedModels()
            await MainActor.run {
                guard let self else { return }
                self.isMLXBenchmarkCacheRefreshing = false
                guard !self.isMLXBenchmarkActive else { return }
                self.downloadedMLXBenchmarkModels = models
            }
        }
    }

    func startMLXBenchmark() {
        guard canStartMLXBenchmark else {
            mlxBenchmarkError = mlxBenchmarkUnavailableReason
            return
        }

        let runID = UUID()
        mlxBenchmarkRunID = runID
        mlxBenchmarkPhase = .starting
        mlxBenchmarkError = nil
        mlxBenchmarkResults = []
        mlxBenchmarkModels = []
        let benchmark = mlxBenchmark
        let session = session
        let precedingDelivery = orderedSessionDelivery
        mlxBenchmarkTask = Task { @concurrent [weak self] in
            var reservationID: UUID?
            do {
                await precedingDelivery?.value
                try Task.checkCancellation()
                let reservedID = try await session.reserveExternalCapture()
                reservationID = reservedID
                let accepted = await MainActor.run { () -> Bool in
                    guard let self, self.mlxBenchmarkRunID == runID,
                        self.mlxBenchmarkPhase == .starting
                    else { return false }
                    self.mlxBenchmarkReservationID = reservedID
                    return true
                }
                guard accepted else { throw CancellationError() }
                try Task.checkCancellation()
                let models = try await benchmark.startRecording { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.handleMLXBenchmarkCaptureFailure(message, runID: runID)
                    }
                }
                try Task.checkCancellation()
                let didStart = await MainActor.run { () -> Bool in
                    guard let self, self.mlxBenchmarkRunID == runID,
                        self.mlxBenchmarkPhase == .starting
                    else { return false }
                    self.downloadedMLXBenchmarkModels = models
                    self.mlxBenchmarkModels = models
                    self.mlxBenchmarkPhase = .recording
                    self.mlxBenchmarkTask = nil
                    return true
                }
                guard didStart else { throw CancellationError() }
            } catch is CancellationError {
                await benchmark.cancel()
                if let reservationID {
                    await session.releaseExternalCapture(reservationID: reservationID)
                }
                await MainActor.run {
                    self?.finishMLXBenchmarkCancellation(runID: runID)
                }
            } catch {
                await benchmark.cancel()
                if let reservationID {
                    await session.releaseExternalCapture(reservationID: reservationID)
                }
                await MainActor.run {
                    guard let self, self.mlxBenchmarkRunID == runID else { return }
                    self.mlxBenchmarkRunID = nil
                    self.mlxBenchmarkReservationID = nil
                    self.mlxBenchmarkModels = []
                    self.mlxBenchmarkTask = nil
                    self.mlxBenchmarkPhase = .idle
                    self.mlxBenchmarkError = error.localizedDescription
                }
            }
        }
    }

    func stopAndRunMLXBenchmark() {
        guard mlxBenchmarkPhase == .recording, mlxBenchmarkModels.count >= 2,
            let runID = mlxBenchmarkRunID,
            let reservationID = mlxBenchmarkReservationID
        else { return }

        let models = mlxBenchmarkModels
        let context = contextualStrings
        let benchmark = mlxBenchmark
        let session = session
        if let first = models.first {
            mlxBenchmarkPhase = .comparing(
                model: first.displayName,
                index: 1,
                total: models.count
            )
        }
        mlxBenchmarkTask = Task { @concurrent [weak self] in
            do {
                let results = try await benchmark.stopAndCompare(
                    models: models,
                    contextualStrings: context
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.mlxBenchmarkRunID == runID,
                            case .comparing = self.mlxBenchmarkPhase
                        else { return }
                        self.mlxBenchmarkPhase = .comparing(
                            model: progress.model.displayName,
                            index: progress.index,
                            total: progress.total
                        )
                    }
                }
                try Task.checkCancellation()
                await session.releaseExternalCapture(reservationID: reservationID)
                await MainActor.run {
                    guard let self, self.mlxBenchmarkRunID == runID else { return }
                    self.mlxBenchmarkRunID = nil
                    self.mlxBenchmarkReservationID = nil
                    self.mlxBenchmarkModels = []
                    self.mlxBenchmarkTask = nil
                    self.mlxBenchmarkResults = results
                    self.mlxBenchmarkPhase = .finished
                    self.refreshMLXBenchmarkModels()
                }
            } catch is CancellationError {
                await benchmark.cancel()
                await session.releaseExternalCapture(reservationID: reservationID)
                await MainActor.run {
                    self?.finishMLXBenchmarkCancellation(runID: runID)
                }
            } catch {
                await benchmark.cancel()
                await session.releaseExternalCapture(reservationID: reservationID)
                await MainActor.run {
                    guard let self, self.mlxBenchmarkRunID == runID else { return }
                    self.mlxBenchmarkRunID = nil
                    self.mlxBenchmarkReservationID = nil
                    self.mlxBenchmarkModels = []
                    self.mlxBenchmarkTask = nil
                    self.mlxBenchmarkPhase = .idle
                    self.mlxBenchmarkError = error.localizedDescription
                }
            }
        }
    }

    func cancelMLXBenchmark() {
        guard isMLXBenchmarkActive, let runID = mlxBenchmarkRunID else { return }
        mlxBenchmarkPhase = .cancelling
        let operation = mlxBenchmarkTask
        operation?.cancel()
        let benchmark = mlxBenchmark
        let reservationID = mlxBenchmarkReservationID
        let session = session
        mlxBenchmarkTask = Task { @concurrent [weak self] in
            await benchmark.cancel()
            _ = await operation?.result
            if let reservationID {
                await session.releaseExternalCapture(reservationID: reservationID)
            }
            await MainActor.run {
                self?.finishMLXBenchmarkCancellation(runID: runID)
            }
        }
    }

    func selectDictationBackend(_ backend: DictationBackend) {
        guard !isMLXBenchmarkActive else {
            selectedDictationBackend = activeDictationBackend
            mlxBenchmarkError = "Finish or cancel the MLX comparison first."
            return
        }
        guard !isDictationModelPreparing else {
            selectedDictationBackend = activeDictationBackend
            return
        }
        guard backend != activeDictationBackend else {
            selectedDictationBackend = activeDictationBackend
            preferences.setDictationBackendIdentifier(backend.preferenceIdentifier)
            return
        }

        let selectionID = UUID()
        dictationSelectionID = selectionID
        selectedDictationBackend = backend
        isDictationModelPreparing = true
        dictationModelError = nil
        failedDictationBackend = nil
        lastMLXMetrics = nil
        dictationModelStatus =
            backend == .apple
            ? "Preparing Apple Speech…"
            : "Preparing \(backend.rawValue)…"
        let terms = contextualStrings

        let candidate: any SpeechRecognizing
        if let model = backend.mlxModel {
            candidate = MLXSpeechRecognizer(
                model: model,
                onPreparation: { [weak self] stage in
                    Task { @MainActor [weak self] in
                        self?.applyMLXPreparation(
                            stage,
                            backend: backend,
                            selectionID: selectionID
                        )
                    }
                },
                shouldSkipSilentShortAudio: { [preferences] in
                    preferences.skipSilentShortMLXAudio
                },
                onMetrics: { [weak self] metrics in
                    Task { @MainActor [weak self] in
                        self?.lastMLXMetrics = metrics
                    }
                }
            )
        } else {
            candidate = AppleSpeechRecognizer()
        }
        preparingDictationCandidate = candidate

        dictationSelectionTask = Task { @concurrent [weak self] in
            do {
                try await candidate.prepare(contextualStrings: terms)
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self, self.dictationSelectionID == selectionID else { return }
                    self.preparingDictationCandidate = nil
                    self.pendingDictationCandidate = PendingDictationCandidate(
                        selectionID: selectionID,
                        backend: backend,
                        recognizer: candidate
                    )
                    self.dictationSelectionTask = nil
                    self.activatePendingDictationCandidateIfPossible()
                }
            } catch is CancellationError {
                await candidate.shutdown()
                await MainActor.run {
                    guard let self, self.dictationSelectionID == selectionID else { return }
                    self.dictationSelectionID = nil
                    self.preparingDictationCandidate = nil
                    self.selectedDictationBackend = self.activeDictationBackend
                    self.isDictationModelPreparing = false
                    self.dictationModelStatus = "Model change cancelled"
                    self.dictationSelectionTask = nil
                }
            } catch {
                await candidate.shutdown()
                await MainActor.run {
                    guard let self, self.dictationSelectionID == selectionID else { return }
                    self.dictationSelectionID = nil
                    self.preparingDictationCandidate = nil
                    self.selectedDictationBackend = self.activeDictationBackend
                    self.isDictationModelPreparing = false
                    self.dictationModelStatus =
                        "\(self.activeDictationBackend.rawValue) remains active"
                    self.dictationModelError = error.localizedDescription
                    self.failedDictationBackend = backend
                    self.dictationSelectionTask = nil
                    self.presentFailure(error.localizedDescription)
                }
            }
        }
    }

    var canCancelDictationModelPreparation: Bool {
        isDictationModelPreparing && !isDictationModelActivating
    }

    func cancelDictationModelPreparation() {
        guard !isDictationModelActivating,
            isDictationModelPreparing || preparingDictationCandidate != nil
                || pendingDictationCandidate != nil
        else { return }
        let preparing = preparingDictationCandidate
        let pending = pendingDictationCandidate?.recognizer
        let selectionTask = dictationSelectionTask
        dictationSelectionID = nil
        selectionTask?.cancel()
        dictationSelectionTask = nil
        preparingDictationCandidate = nil
        pendingDictationCandidate = nil
        isDictationModelActivating = true
        isDictationModelPreparing = true
        selectedDictationBackend = activeDictationBackend
        dictationModelStatus = "Cancelling model preparation…"
        Task { @concurrent [weak self] in
            await preparing?.shutdown()
            await pending?.shutdown()
            _ = await selectionTask?.result
            await MainActor.run {
                guard let self, self.dictationSelectionID == nil else { return }
                self.isDictationModelActivating = false
                self.isDictationModelPreparing = false
                self.dictationModelStatus = "\(self.activeDictationBackend.rawValue) ready"
            }
        }
    }

    func retryFailedDictationBackend() {
        guard let failedDictationBackend else { return }
        selectDictationBackend(failedDictationBackend)
    }

    func removeDownloadedMLXModels() {
        guard activeDictationBackend == .apple, !isDictationModelPreparing,
            !isMLXBenchmarkActive, !isMLXBenchmarkCacheRefreshing,
            activeSpeechBackend == .system, !isSpeechModelPreparing
        else {
            let reason =
                if isMLXBenchmarkActive || isMLXBenchmarkCacheRefreshing {
                    "Wait for the MLX comparison activity to finish."
                } else if activeSpeechBackend != .system || isSpeechModelPreparing {
                    "Switch the spoken voice to System (Apple) before removing MLX models."
                } else {
                    "Switch to Apple Speech before removing MLX models."
                }
            presentFailure(reason)
            return
        }
        do {
            let modelStoreURL = MLXSpeechRecognizer.modelStoreURL
            if FileManager.default.fileExists(atPath: modelStoreURL.path) {
                try FileManager.default.removeItem(at: modelStoreURL)
            }
            lastMLXMetrics = nil
            downloadedMLXBenchmarkModels = []
            mlxBenchmarkResults = []
            dictationModelError = nil
            dictationModelStatus = "Downloaded MLX models removed"
        } catch {
            dictationModelError = error.localizedDescription
            presentFailure(error.localizedDescription)
        }
    }

    func exportLastSession() {
        guard !lastExportableText.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Voice Session"
        panel.nameFieldStringValue = "voice-session.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try lastExportableText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentFailure(error.localizedDescription)
        }
    }

    private func rebuildLexicon(for projectURL: URL) {
        Task { @concurrent [weak self] in
            do {
                let terms = try await ProjectLexicon().contextualStrings(in: projectURL)
                await MainActor.run {
                    guard let self else { return }
                    // A slow scan of a previously selected project must not
                    // overwrite the lexicon of the current selection.
                    guard self.projectURL == projectURL else { return }
                    self.projectContextualStrings = terms
                    self.refreshContextualStrings()
                }
            } catch {
                await MainActor.run {
                    self?.presentFailure(error.localizedDescription)
                }
            }
        }
    }

    /// Reads the persisted vocabulary rather than the settings field, so a
    /// project rescan cannot push half-typed, unapplied text at the recognizer.
    private func refreshContextualStrings() {
        let preferred = ManualSpeechVocabulary.terms(
            from: preferences.manualSpeechVocabulary
        )
        let terms = ManualSpeechVocabulary.merge(
            preferredTerms: preferred,
            projectTerms: projectContextualStrings
        )
        contextualStrings = terms
        // Report what the recognizer actually receives: preferred spellings can
        // crowd project terms out of the merged budget.
        lexiconCount = terms.count
        enqueueOrderedSessionDelivery { session in
            await session.setContextualStrings(terms)
        }
    }

    private func scheduleMLXIdleUnload() {
        mlxIdleUnloadTask?.cancel()
        mlxIdleUnloadTask = nil
        guard mlxIdleUnloadDelay != .never,
            activeDictationBackend != .apple,
            presentation.phase == .idle || presentation.phase == .failed,
            !isMLXBenchmarkActive,
            !isDictationModelPreparing
        else {
            return
        }

        let delay = Duration.seconds(mlxIdleUnloadDelay.rawValue * 60)
        let expectedBackend = activeDictationBackend
        mlxIdleUnloadTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.activeDictationBackend == expectedBackend else { return }
            await self.unloadIdleMLXRecognizer(expectedBackend: expectedBackend)
        }
    }

    private func unloadMLXResourcesForSleep() {
        guard mlxIdleUnloadDelay != .never,
            activeDictationBackend != .apple
        else {
            return
        }
        mlxIdleUnloadTask?.cancel()
        mlxIdleUnloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.unloadIdleMLXRecognizer(
                expectedBackend: self.activeDictationBackend
            )
        }
    }

    private func unloadIdleMLXRecognizer(
        expectedBackend: DictationBackend
    ) async {
        guard expectedBackend != .apple,
            activeDictationBackend == expectedBackend,
            presentation.phase == .idle || presentation.phase == .failed,
            !isMLXBenchmarkActive,
            !isDictationModelPreparing
        else {
            return
        }
        let unloaded = await session.unloadRecognizerIfIdle()
        guard unloaded, activeDictationBackend == expectedBackend else { return }
        // `mlxIdleUnloadTask` is deliberately left alone: a schedule that ran
        // while this awaited already stored a newer timer there, and clearing
        // it would leave that timer running with nothing able to cancel it.
        dictationModelStatus =
            "\(expectedBackend.rawValue) unloaded · reloads on next dictation"
    }

    private func hotkeyPressed(eventID: UInt64, mode: CleanupMode) {
        guard eventID > lastObservedHotkeyEventID else { return }
        lastObservedHotkeyEventID = eventID
        lastHotkeyDetection = mode == .polish ? "Polish detected" : "Conservative detected"
        isHotkeyHeld = true
        if isMLXBenchmarkActive {
            isHotkeyHeld = false
            presentFailure("Finish or cancel the MLX comparison before dictating.")
            return
        }
        if isDictationModelActivating || pendingDictationCandidate != nil {
            isHotkeyHeld = false
            presentFailure(
                "Activating the selected speech model. Try the hotkey again in a moment.")
            return
        }
        let destination = destination
        enqueueOrderedSessionDelivery { session in
            await session.handleHotkeyPress(
                eventID: eventID,
                mode: mode,
                planning: destination == .planning
            )
        }
    }

    private func hotkeyReleased(eventID: UInt64) {
        guard eventID > lastObservedHotkeyEventID else { return }
        lastObservedHotkeyEventID = eventID
        isHotkeyHeld = false
        guard !isMLXBenchmarkActive else { return }
        enqueueOrderedSessionDelivery { session in
            await session.handleHotkeyRelease(eventID: eventID)
        }
        guard pendingDictationCandidate != nil else { return }
        let delivery = orderedSessionDelivery
        Task { @concurrent [weak self] in
            await delivery?.value
            await MainActor.run {
                self?.activatePendingDictationCandidateIfPossible()
            }
        }
    }

    /// Independently spawned Tasks reach the VoiceSession actor in no defined
    /// order, which lets a release overtake its press (dropping the capture) or
    /// two settings changes apply in reverse. Chaining on the previous delivery
    /// preserves submission order.
    private func enqueueOrderedSessionDelivery(
        _ operation: @escaping @Sendable (VoiceSession) async -> Void
    ) {
        let previous = orderedSessionDelivery
        let session = session
        orderedSessionDelivery = Task { @concurrent in
            await previous?.value
            await operation(session)
        }
    }

    private func presentFailure(_ message: String) {
        apply(.init(phase: .failed, message: message))
    }

    private var mlxBenchmarkUnavailableReason: String {
        if activeDictationBackend != .apple {
            return "Switch to Apple Speech before running an MLX comparison."
        }
        if downloadedMLXBenchmarkModels.count < 2 {
            return "Select and download at least two MLX models before comparing them."
        }
        if isDictationModelPreparing {
            return "Wait for speech-model preparation to finish."
        }
        if isHotkeyHeld || ![.idle, .failed].contains(presentation.phase) {
            return "Finish the current Voice turn before recording a comparison."
        }
        return "An MLX comparison is already active."
    }

    private func handleMLXBenchmarkCaptureFailure(_ message: String, runID: UUID) {
        guard mlxBenchmarkRunID == runID else { return }
        mlxBenchmarkError = message
        presentFailure(message)
        cancelMLXBenchmark()
    }

    private func finishMLXBenchmarkCancellation(runID: UUID) {
        guard mlxBenchmarkRunID == runID else { return }
        mlxBenchmarkRunID = nil
        mlxBenchmarkReservationID = nil
        mlxBenchmarkModels = []
        mlxBenchmarkTask = nil
        mlxBenchmarkPhase = .idle
        refreshMLXBenchmarkModels()
    }

    private func applyMLXPreparation(
        _ stage: MLXModelPreparationStage,
        backend: DictationBackend,
        selectionID: UUID
    ) {
        guard dictationSelectionID == selectionID,
            isDictationModelPreparing,
            !isDictationModelActivating
        else { return }
        switch stage {
        case .downloading(let fraction):
            dictationModelStatus = String(
                format: "Downloading %@ · %.0f%%",
                backend.rawValue,
                fraction * 100
            )
        case .loading:
            dictationModelStatus = "Loading \(backend.rawValue) into memory…"
        case .ready:
            dictationModelStatus = "Activating \(backend.rawValue)…"
        }
    }

    private func apply(_ presentation: VoicePresentation) {
        if presentation.revision != 0 {
            guard presentation.revision > lastPresentationRevision else { return }
            lastPresentationRevision = presentation.revision
        }
        self.presentation = presentation
        if presentation.phase == .idle || presentation.phase == .failed {
            scheduleMLXIdleUnload()
        } else {
            mlxIdleUnloadTask?.cancel()
            mlxIdleUnloadTask = nil
        }
        if presentation.phase == .listening, activeDictationBackend != .apple {
            // Every partial transcript republishes .listening; assigning an
            // identical @Observable value would invalidate Settings each time.
            let readyStatus = "\(activeDictationBackend.rawValue) ready"
            if dictationModelStatus != readyStatus {
                dictationModelStatus = readyStatus
            }
        }
        switch presentation.phase {
        case .cleaning:
            lastRawTranscript = presentation.transcript
            lastCleanedTranscript = ""
            lastCleanupSource = nil
        case .inserting, .planning, .speaking:
            if !presentation.transcript.isEmpty {
                lastCleanedTranscript = presentation.transcript
                lastCleanupSource = presentation.cleanupSource
            }
        default:
            break
        }
        if presentation.phase == .idle || presentation.phase == .failed {
            activatePendingDictationCandidateIfPossible()
        }
        if !presentation.transcript.isEmpty {
            lastExportableText = """
                # Voice Session

                ## Dictation

                \(presentation.transcript)

                ## Response

                \(presentation.isConnectedPlanning ? presentation.message : "")
                """
        }
        overlay.update(
            with: presentation,
            onDevicePlanning: planningBackend == .onDevice
        )
        if presentation.phase == .failed {
            NSSound.beep()
        }
    }

    private func activatePendingDictationCandidateIfPossible() {
        guard !isDictationModelActivating,
            let pending = pendingDictationCandidate,
            presentation.phase == .idle || presentation.phase == .failed
        else {
            if pendingDictationCandidate != nil {
                dictationModelStatus = "Model loaded · waiting for the current turn to finish"
            }
            return
        }

        isDictationModelActivating = true
        dictationModelStatus = "Activating \(pending.backend.rawValue)…"
        let session = session
        let precedingDelivery = orderedSessionDelivery
        dictationSelectionTask = Task { @concurrent [weak self] in
            do {
                await precedingDelivery?.value
                try await session.replaceRecognizer(
                    with: pending.recognizer,
                    name: pending.backend.rawValue
                )
                await MainActor.run {
                    guard let self,
                        self.dictationSelectionID == pending.selectionID
                    else { return }
                    self.dictationSelectionID = nil
                    self.pendingDictationCandidate = nil
                    self.activeDictationBackend = pending.backend
                    self.selectedDictationBackend = pending.backend
                    self.preferences.setDictationBackendIdentifier(
                        pending.backend.preferenceIdentifier
                    )
                    self.isDictationModelActivating = false
                    self.isDictationModelPreparing = false
                    self.dictationModelStatus = "\(pending.backend.rawValue) ready"
                    self.dictationSelectionTask = nil
                    self.refreshMLXBenchmarkModels()
                }
            } catch VoiceSessionRecognizerError.busy {
                await MainActor.run {
                    guard let self,
                        self.dictationSelectionID == pending.selectionID
                    else { return }
                    self.isDictationModelActivating = false
                    self.dictationModelStatus =
                        "Model loaded · waiting for the current turn to finish"
                    self.dictationSelectionTask = nil
                }
            } catch is CancellationError {
                await pending.recognizer.shutdown()
                await MainActor.run {
                    guard let self,
                        self.dictationSelectionID == pending.selectionID
                    else { return }
                    self.dictationSelectionID = nil
                    self.pendingDictationCandidate = nil
                    self.selectedDictationBackend = self.activeDictationBackend
                    self.isDictationModelActivating = false
                    self.isDictationModelPreparing = false
                    self.dictationModelStatus = "Model change cancelled"
                    self.dictationSelectionTask = nil
                }
            } catch {
                await pending.recognizer.shutdown()
                await MainActor.run {
                    guard let self,
                        self.dictationSelectionID == pending.selectionID
                    else { return }
                    self.dictationSelectionID = nil
                    self.pendingDictationCandidate = nil
                    self.selectedDictationBackend = self.activeDictationBackend
                    self.isDictationModelActivating = false
                    self.isDictationModelPreparing = false
                    self.dictationModelStatus =
                        "\(self.activeDictationBackend.rawValue) remains active"
                    self.dictationModelError = error.localizedDescription
                    self.failedDictationBackend = pending.backend
                    self.dictationSelectionTask = nil
                    self.presentFailure(error.localizedDescription)
                }
            }
        }
    }

    private static var historyStorageURL: URL {
        let base =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        return
            base
            .appendingPathComponent("io.blacktop.Voice", isDirectory: true)
            .appendingPathComponent("history.voicehistory")
    }
}
