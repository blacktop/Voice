# voice-say

`voice-say` brings Voice's local voices to scripts and agents.
Follow the [build and install guide](../README.md#build-and-install) to set up
the toolchain and signing, then try it:

```fish
just install-cli    # builds and installs voice-say to ~/.local/bin, no sudo
voice-say "Build finished."
voice-say --tier large --style "calm and unhurried" "Deploy is green."
voice-say --describe "a warm narrator with a South African accent" "Ready."
echo "piped text" | voice-say --voice Aiden
voice-say --file notes.txt
voice-say --file notes.md --timings
voice-say --file notes.md --announce-pause
```

By default, it uses the app's saved MLX voice settings, so it can reuse a
checkpoint you've already downloaded. Breeze is opt-in because it takes longer
to start speaking. If the app uses Breeze, the CLI falls back to Qwen3's small
preset checkpoint and the stored preset speaker. Pass `--engine breeze` with
`--describe` or `--clone` to select Breeze explicitly.

Each flag overrides only the setting it names. `--help` lists every option,
`--list-voices` shows presets and download sizes, and
`--generate-completion-script fish` emits shell completions.

Only one `voice-say` speaks at a time. If another invocation is already speaking,
the new one skips its work and exits 0. Pass `--wait` when the announcement
should wait its turn.

Use `just install-cli` instead of copying the executable by itself. MLX needs
the Metal resource bundles beside the real binary; the installer keeps them
together and puts an exec wrapper on PATH. The app also includes a copy at
`Voice.app/Contents/MacOS/voice-say`.

## Reading documents

Text arguments are spoken as plain text, with audio playing as model chunks
arrive. Files and stdin go through Markdown narration. `--file` (`-f`) accepts
UTF-8 text and Markdown, up to 4 MiB; PDF and Word extraction isn't supported.
The path must name a regular file. Use `--file -` for piped input, and don't
combine a file with text arguments.

The narrator reads prose. Headings, blockquotes, paragraphs made entirely of a
quotation, and labels such as "Swift code" or "Table" use the checkpoint's other
preset speaker. Ryan's counterpart is Aiden, and vice versa. Described and
cloned voices keep the same speaker and change the delivery for each role.

Heading markers, setext underlines, and thematic breaks are omitted. List
markers are stripped, with a sentence boundary between items. A closed YAML
front-matter block is skipped at the start of a document. Other substitutions
keep dense agent output listenable:

- Fenced code becomes a short label such as "C code" or "Code block".
  Indented text, including error output and list continuations, stays speakable.
- Markdown and HTML tables become "Table".
- Hexadecimal addresses with at least eight digits after `0x` become "code
  address".
- Short URLs speak the host, such as "google dot com". A URL longer than
  48 characters, or one with a query or fragment, becomes "google URL".
  Subdomains and compound suffixes are preserved; paths and queries aren't
  spoken. Markdown links and images keep their readable labels.

These rules also apply with `--stream`. If no speakable text or omission cue
remains, the command exits before loading a model.

In interactive `--file` mode, press **Space** to pause or resume; Enter isn't
needed. The terminal displays "Paused" or "Resumed". Add `--announce-pause`
for spoken feedback from the system voice. While paused, synthesis can fill
the bounded playback queue and then waits. Ctrl-C stops narration, and the
terminal is restored on exit or job suspension. Keyboard controls use the
controlling terminal separately from stdin, so they also work with `--file -`.
Background jobs don't capture keys. Use `--no-controls` to disable them.

## Playback and tuning

Document narration prepares one paragraph while earlier audio plays. A
paragraph under about 500 characters stays in one synthesis call, which helps
keep the voice consistent. Longer paragraphs split between sentences; a single
sentence over 600 characters may split at a clause. For Qwen3 preset and
described voices, the runtime prefills the complete text before generation to
avoid the pacing drift of its streaming prompt layout. This comes from the
pinned mlx-audio-swift patch.

One loaded model produces audio in order. The player holds at most four
segments, plus one being prepared. Each segment is capped at 90 seconds of
decoded audio in both buffered and streaming modes. An overlong segment is
cancelled, reported on stderr, and skipped. Empty segments are also reported
and skipped. The command fails if the entire input produces no audio; these
diagnostics remain visible with `--quiet`.

Buffered playback trims quiet edges conservatively, leaving about 220 ms
between sentence groups and a full second between paragraphs. It preserves
breaths and pauses inside a group. The first group must finish synthesizing
before playback starts. `--stream` starts playing raw chunks sooner and skips
that pause normalization.

The default temperature is 0.6, below the model's 0.9, to reduce changes in
pitch and energy between utterances. `--temperature` adjusts the tradeoff with
expressiveness; 0 selects greedy sampling. `--seed` resets the sampler for
each utterance so a document can be read the same way again. Top-k is 50.
Described voices can choose a slightly different speaker on each call, so a
preset or clone is steadier for long reads.

`--speed` uses pitch-preserving time stretching during playback. For example,
`--speed 1.2` reads 20% faster and shortens pauses by the same factor. It works
with every model without relying on the model to follow pace instructions.

Use `--timings` to report model preparation, synthesis and audio durations,
trimmed silence, the longest internal quiet interval, queue wait, and playback
idle time. Output goes to stderr even with `--quiet`. Compare the same text
with `--stream --timings` to distinguish silence in the generated audio from
gaps while the player waits for more. Streaming synthesis times exclude queue
waits and are approximate because decoding can continue during those waits.
Buffering can't hide sustained synthesis that's slower than playback.

## Notifications

Add `--notify` to post a Mac notification alongside speech:

```fish
voice-say --notify --notify-title "Build · Voice" \
    --notify-group voice-build "All checks passed."
```

Use `--notify-zed-project /absolute/project/path` to attach a Zed project.
The [notification guide](voice-notify.md#zed-projects) explains window-selection
limits, metadata overrides, speech-lock behavior, and optional phone push.
