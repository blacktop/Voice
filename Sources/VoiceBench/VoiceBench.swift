import Foundation
import VoiceCore
import VoiceMLX

/// Measures each downloaded MLX dictation model against a local corpus of
/// recorded clips with reference transcripts, reporting per-model word error
/// rate and real-time factor. The corpus never leaves this Mac.
///
/// Usage: VoiceBench [corpus-directory]
///
/// The corpus directory contains pairs like `note-taking.wav` (any format
/// AVAudioFile reads) and `note-taking.txt` (the exact words spoken).
@main
struct VoiceBench {
    static func main() async {
        let corpusPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Bench/corpus"
        do {
            try await run(corpusPath: corpusPath)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(corpusPath: String) async throws {
        let corpusURL = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let corpus = try loadCorpus(at: corpusURL)
        guard !corpus.isEmpty else {
            throw BenchError.emptyCorpus(corpusURL.path(percentEncoded: false))
        }
        let models = await MLXCorpusBenchmark.downloadedModels()
        guard !models.isEmpty else {
            throw MLXCorpusBenchmarkError.noModels
        }
        let modelNames = models.map(\.displayName).joined(separator: ", ")
        print("Corpus: \(corpus.count) clips · Models: \(modelNames)")

        let results = try await MLXCorpusBenchmark.run(
            clips: corpus.map { MLXCorpusClip(name: $0.name, audioURL: $0.audioURL) },
            models: models,
            onProgress: { print("  \($0)") }
        )
        report(results: results, references: corpus)
    }

    struct CorpusEntry {
        let name: String
        let audioURL: URL
        let referenceText: String
    }

    enum BenchError: LocalizedError {
        case emptyCorpus(String)

        var errorDescription: String? {
            switch self {
            case .emptyCorpus(let path):
                "No clip/transcript pairs found in \(path). Add note-taking.wav "
                    + "plus note-taking.txt (the exact words spoken) and re-run."
            }
        }
    }

    static func loadCorpus(at directory: URL) throws -> [CorpusEntry] {
        let audioExtensions: Set<String> = ["wav", "m4a", "mp3", "aiff", "caf", "flac"]
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        var entries: [CorpusEntry] = []
        for audioURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where audioExtensions.contains(audioURL.pathExtension.lowercased()) {
            let referenceURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
            guard let reference = try? String(contentsOf: referenceURL, encoding: .utf8),
                !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                print("skipping \(audioURL.lastPathComponent): no sibling .txt reference")
                continue
            }
            entries.append(
                CorpusEntry(
                    name: audioURL.deletingPathExtension().lastPathComponent,
                    audioURL: audioURL,
                    referenceText: reference
                )
            )
        }
        return entries
    }

    static func report(results: [MLXCorpusModelResult], references: [CorpusEntry]) {
        let referenceByName = Dictionary(
            uniqueKeysWithValues: references.map { ($0.name, $0.referenceText) }
        )
        print("")
        print(row("model", "WER", "S/I/D", "mean RTF", "clips"))
        print(String(repeating: "-", count: 88))
        for result in results {
            var errors = 0
            var referenceWords = 0
            var substitutions = 0
            var insertions = 0
            var deletions = 0
            var rtfValues: [Double] = []
            var failures = 0
            for clip in result.clips {
                guard let transcript = clip.transcript,
                    let reference = referenceByName[clip.clipName]
                else {
                    failures += 1
                    continue
                }
                let wer = WordErrorRate.compute(reference: reference, hypothesis: transcript)
                errors += wer.errorCount
                referenceWords += wer.referenceWordCount
                substitutions += wer.substitutions
                insertions += wer.insertions
                deletions += wer.deletions
                if let rtf = clip.realTimeFactor {
                    rtfValues.append(rtf)
                }
            }
            let werText =
                referenceWords > 0
                ? String(format: "%.1f%%", 100 * Double(errors) / Double(referenceWords))
                : "n/a"
            let rtfText =
                rtfValues.isEmpty
                ? "n/a"
                : String(format: "%.2fx", rtfValues.reduce(0, +) / Double(rtfValues.count))
            let clipText =
                failures == 0
                ? "\(result.clips.count)" : "\(result.clips.count - failures)/\(result.clips.count)"
            print(
                row(
                    result.model.displayName,
                    werText,
                    "\(substitutions)/\(insertions)/\(deletions)",
                    rtfText,
                    clipText
                )
            )
        }
        print("")
        print("WER is corpus-weighted: total errors over total reference words.")
    }

    static func row(_ columns: String...) -> String {
        let widths = [44, 8, 10, 10, 8]
        return zip(columns, widths)
            .map { column, width in column.padding(toLength: width, withPad: " ", startingAt: 0) }
            .joined(separator: " ")
    }
}
