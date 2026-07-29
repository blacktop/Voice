# Architecture and platform strategy

Voice is split into five targets so privacy-sensitive code has a visible seam:

- `VoiceCore` owns transcripts, cleanup validation, protected spans, and agent
  transport contracts. It has no UI, microphone, process, or network access.
- `VoicePlatform` owns public Apple frameworks, encrypted local storage, and
  explicit agent-process transports.
- `VoiceExperimental` may capability-probe private Apple frameworks. The app
  does not link them and never requires them.
- `VoiceMLX` owns the optional Apple-Silicon PCM capture, pinned model download,
  and native MLX ASR adapter. It depends on `VoiceCore`, not `VoicePlatform`.
- `Voice` is the SwiftUI menu-bar app and privacy-boundary selector.

## Latency path

Apple Speech feeds `SpeechAnalyzer` incrementally in 1,024-frame buffers.
`DictationTranscriber` requests volatile results, frequent finalization, and
punctuation. Etiquette replacements are deliberately not requested: they redact
words Apple classifies as expletives into asterisks, and dictation must
reproduce what the user said verbatim. The analyzer is prepared before capture
and retains its model for the process lifetime.

The experimental MLX path separately converts microphone input to 16 kHz mono
Float32 chunks and keeps those chunks only in memory, with a ten-minute hard
limit. On hotkey release it passes one complete sample array to the selected
Qwen3, Granite, Cohere, or Parakeet model and emits one final
`TranscriptEvent`. This avoids forcing MLX tensors into `VoiceCore` and avoids
destabilizing Apple's Speech-specific capture path. It also means the current
MLX path has no live partial transcript and pays its inference latency after
release.

All recognizers implement the same `SpeechRecognizing` contract. Backend swaps
prepare a candidate first and replace the active recognizer only while the voice
session is idle. After the swap only the selected MLX model remains active, but
an MLX-to-MLX change temporarily holds both models in unified memory so the
previous recognizer remains usable until the candidate is ready. A project
lexicon contributes at most 100 filename-derived terms without reading file
contents. Apple Speech installs those terms in `AnalysisContext`; Qwen formats
them as spelling hints, and Granite appends them as keywords to its transcription
prompt. Cohere and Parakeet are forced to English but receive no project terms
because their selected generation interfaces expose no equivalent contextual
spelling hook.

The app stores only a stable backend identifier after a candidate finishes
preparation and becomes active. Startup restores that successful selection; a
failed or cancelled change leaves both the active backend and the stored
identifier unchanged. Model weights have a separate lifetime in the
Application Support cache.

Conservative cleanup is deterministic: it handles punctuation, casing, spoken
punctuation, fillers, and exact repetition without allowing a generative model
to change coding intent. Polish mode is the explicit Apple Foundation Models
path. Each Polish turn uses a fresh session and returns source-anchored typed
UTF-16 edits, not replacement prose. The validator requires every original
substring to match, then rejects overlaps, invalid Unicode boundaries,
protected-token changes, unsafe control characters, and edits outside the mode
budget. Any model or validation failure returns the deterministic result.

Text insertion first uses the selected-text Accessibility attribute. If that is
unsupported, cmux and Ghostty use the PID-targeted Unicode event fallback
automatically, and every other app reaches it through the compatibility
setting, which defaults to on and can be turned off to require direct
insertion everywhere. Compatibility text is stripped of newline runs, emitted as one complete
extended grapheme per event, briefly paced, and delivered only while the
captured element remains focused. Clipboard paste is disabled by default and,
if explicitly enabled in code, snapshots and restores the clipboard. No path
sends Return.

## Planning transports

`LocalFoundationModelTransport` is memory-only and tool-free. It streams the
on-device Apple model into the planning window and the response is spoken with
`AVSpeechSynthesizer`, or with the opt-in local Qwen3-TTS model routed through
`SwitchableSpeechOutput`. MLX synthesis streams audio chunks so playback starts
before the full response is generated. Starting the next capture stops speech
immediately regardless of engine. The planning window and menu-bar menu also
expose **Stop Speaking**, which ends playback without interrupting or
disconnecting the completed agent turn.

`CodexAppServerTransport` launches the selected executable directly, without a
shell or credential inspection. It requests a read-only sandbox, disables
approvals, blocks network in the turn policy, and sends only finalized text.
The app-server still receives the project working directory and may read files
inside its read-only sandbox or send that context to its configured model.

`ACPAgentTransport` supports Agent Client Protocol v1 over stdio JSON-RPC. It
denies permission requests, uses no MCP servers, and cancels the remote turn when
the voice turn or stream consumer is cancelled. It advertises ACP terminal
authentication and, after an authentication-required response, opens the first
agent-advertised terminal login command against the same executable in Terminal,
sends ACP `authenticate` with that method's ID, and retries the request once.
Session setup also consumes ACP `configOptions` and
the app renders supported select and boolean options dynamically instead of
hardcoding an agent's model catalog. Changes use `session/set_config_option`;
the full returned state and later `config_option_update` notifications replace
the local state atomically. Successful select values are restored per ACP
launcher on the next session when that agent still advertises them.

## macOS 27

The macOS 26 implementation already asks `SystemLanguageModel` and
`SpeechAnalyzer` for the system-provided assets. Those public entry points pick up
new model weights and OS-side performance improvements after an OS update. Apple
specifically notes that the on-device Foundation Model changes on macOS 27, so
prompt and latency regression tests must be rerun on that OS.

The project now builds against the macOS 27 SDK, and the first macOS 27-only
adapter is compiled: `AnalyzerInputConversion` wraps `AnalyzerInputConverter`
behind an `@available(macOS 27, *)` check, so
`VoicePlatformCapabilities.hasCompiledMacOS27Adapters` reports true while
`runsOnMacOS27OrLater` still reports the host OS separately. The macOS 26 path
remains the fallback and is still compiled.

## MLX boundary

MLX cannot accelerate `SpeechAnalyzer` or Apple's Foundation Models because
those frameworks do not expose their tensors. Voice instead treats MLX as a
parallel recognition implementation in its own target. Every recognizer uses
the same deterministic Conservative path and opt-in Foundation Models Polish
path, which keeps raw ASR quality and cleanup quality separable during
evaluation. Settings retains the last raw and cleaned strings in memory only so
the next bad turn can be attributed without saving microphone audio.

The integration pins `mlx-audio-swift` 0.1.3, MLX Swift 0.31.3, MLX Swift LM
3.31.3, Swift Transformers 1.2.1, and immutable Hugging Face revisions for both
Qwen3 models plus Granite 4.0 Speech 1B 5-bit, Cohere Transcribe 2B 8-bit, and
Parakeet TDT 0.6B v3. Downloads use an explicit unauthenticated `HubClient` and
public Hugging Face storage/CDN infrastructure; Voice does not consult shell
configuration or credentials. Qwen and Granite tokenizer parsing uses a
separate explicitly offline, cacheless `HubApi` with a fixed empty token rather
than the dependency's environment-aware shared default. The downloaded weights
live in an app-specific Application Support model store that is excluded from
backups. One selected model is kept warm, model-specific context rules are
applied as described above, greedy decoding is used where supported, and audio
never enters the download path.

This is deliberately experimental. The native ASR package is young, model
weights add roughly 1.0 GB to 2.5 GB each of persistent storage and substantial
unified-memory pressure, and current decoding is final-result rather than true
microphone streaming. The app reports per-turn latency and runtime peak memory
so model quality can be compared against those costs. Published WER, real-time
factor, and throughput figures were produced with different data, hardware, and
decoding stacks; they are discovery signals, not a ranking for Voice. No
accuracy or speed ordering is assumed without a labeled local
coding-dictation corpus.

The same-audio comparison path has an explicit privacy and memory
contract. It reuses one captured PCM array only with models already present in
the local cache, loads and evaluates candidates sequentially rather than holding
them all active, and retains comparison text and metrics only in memory.
Completion or cancellation releases the captured audio. Comparison never
triggers a model download. Qwen checks cancellation during decoding. The pinned
Granite, Cohere, and Parakeet stream initializers perform a model pass
synchronously, so cancellation waits for the current pass before unloading and
does not begin the next candidate.
