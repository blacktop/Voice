# Privacy boundaries

| Data | Default destination | Retention |
| --- | --- | --- |
| Microphone buffers | Selected Apple or MLX recognizer in this process | Never written to disk; MLX has a ten-minute in-memory limit |
| Volatile partial transcript results | In-memory transcript assembler | Discarded after the turn |
| Final transcript | Deterministic Conservative cleanup or opt-in Apple on-device Polish cleanup | The finalized prompt is stored only when history is enabled |
| Last-turn text diagnostic | Settings, in memory only | Final raw and cleaned strings are overwritten by the next completed turn, cleared on request, and lost when Voice quits |
| Project vocabulary | Names and identifier fragments under the chosen directory | In memory; at most 100 terms; supplied to Apple Speech, Qwen, and Granite; not supplied to Cohere or Parakeet |
| MLX model weights | Pinned public Hugging Face snapshot selected in Settings | App-specific Application Support model store; excluded from backups; retained across launches; removable in Settings after switching to Apple Speech and the System spoken voice |
| Dictation backend preference | App `UserDefaults` domain | Stable backend identifier only; written after successful activation and retained across launches |
| Same-audio MLX comparison | Already cached local models, one at a time | Captured PCM, candidate transcripts, and metrics stay in memory; audio is discarded after completion or cancellation |
| On-device planning prompt and response | Apple `SystemLanguageModel` | Memory-only session |
| Codex or ACP planning prompt | Selected local agent process | Finalized text only; agent policy applies |
| Selected project during agent planning | Codex read-only sandbox or ACP working directory | The agent may read or transmit project context |
| ACP model, effort, mode, and other select choices | App `UserDefaults` domain | Successful string choices only, scoped to the selected ACP launcher; boolean session toggles are not retained |
| Spoken response | `AVSpeechSynthesizer`, or the opt-in local Qwen3-TTS model in this process | Not retained by Voice; MLX synthesis receives the response text only and produces audio in memory |
| Voice-clone reference clip | Local file chosen by the user, read by the local Qwen3-TTS Base model | Never uploaded; conditioned in memory per session; the file path and transcript persist in `UserDefaults` |
| Local history | App support file | Off by default; AES-GCM; bounded to 500 entries; disabling history does not delete existing data |
| History key | macOS Keychain | `WhenUnlockedThisDeviceOnly` |
| Export | User-selected path | Explicit user action only |

Direct Accessibility insertion is the default and remains bound to the exact
captured element. When direct insertion is unsupported, Voice falls back to
PID-targeted Unicode events: automatically for cmux and Ghostty, and for every
other app through the compatibility setting, which is **on by default** and can
be turned off in Settings to require direct insertion everywhere. Apps that
accept direct insertion never reach the fallback. Voice checks that the
captured element is still focused before every grapheme event and aborts without
refocusing if it changed. Focus can still change within the target process in
the small interval between validation and event delivery.

Voice does not inspect shell startup files, credentials, or environment
variables. The MLX downloader uses public Hugging Face infrastructure,
including storage and CDN endpoints, with no bearer token and an app-specific
Application Support model store that is excluded from backups. Qwen and Granite
tokenizers are parsed through an explicitly offline, cacheless client with a
fixed empty token, avoiding the dependency's environment-aware shared default.
Network access occurs only after an MLX model is explicitly selected. Requests
are limited to public model metadata and model files; Voice sends no audio,
transcripts, vocabulary, or project files.
Downloaded weights live under
`~/Library/Application Support/io.blacktop.Voice/MLXModels`.

The same-audio comparison mode does not widen that network boundary: it
uses only model snapshots already present in this store, runs one candidate at
a time, and never downloads missing models. Its captured PCM is not written to
disk and is discarded when comparison completes or is cancelled. Candidate
text and timing remain memory-only unless a later, separately documented export
action is added. The pinned Granite, Cohere, and Parakeet decoders cannot stop
mid-pass, so cancellation retains the PCM until the current pass returns and is
then unloaded; no later candidate is started.

Agent executables are launched directly with a minimal `HOME`, `TMPDIR`, and
standard macOS/Homebrew `PATH`; arbitrary parent-process variables and tokens are
not inherited. The Codex transport requests read-only,
no-approval planning and disables tool-command network access. Codex still uses
its configured model/account and can read project files inside the read-only
sandbox. A different ACP agent is also a separate trust boundary and must enforce
its own sandbox. If that agent requires authentication, Voice opens the terminal
login command the agent advertises in Terminal with the same minimal environment,
sends the selected method ID through ACP, and retries the failed request once.
Voice neither asks for nor stores the resulting credentials; their storage and
network behavior belong to the agent.

Private Apple framework handling is discovery-only. `VoiceExperimental` uses
explicitly opt-in filesystem-presence probes and makes no private calls. A probe
being loadable does not imply entitlement, stability, legality for distribution,
or permission to ship it. Public `SpeechAnalyzer`, `SystemLanguageModel`, and
`AVSpeechSynthesizer` remain the Apple product path; the optional MLX path uses
public open-source packages and model weights.
