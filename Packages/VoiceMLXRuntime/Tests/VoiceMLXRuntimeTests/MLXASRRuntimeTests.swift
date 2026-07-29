import Foundation
import MLXAudioSTT
import Testing

@testable import VoiceMLXRuntime

@Suite
struct MLXASRRuntimeTests {
    @Test
    func cohereGenerationUsesBoundedChunksAndExpandedTokenBudget() {
        let defaults = STTGenerateParameters(
            maxTokens: 1_024,
            temperature: 0.25,
            topP: 0.8,
            topK: 12,
            verbose: true,
            language: nil,
            chunkDuration: 1_200,
            minChunkDuration: 1.25,
            repetitionPenalty: 1.1,
            repetitionContextSize: 48
        )

        let parameters = MLXASRRuntime.cohereGenerationParameters(
            from: defaults
        )

        #expect(parameters.maxTokens == 4_096)
        #expect(parameters.chunkDuration == 30)
        #expect(parameters.chunkDuration + 5 <= 35)
        #expect(parameters.minChunkDuration == defaults.minChunkDuration)
        #expect(parameters.language == "en")
        #expect(parameters.temperature == defaults.temperature)
        #expect(parameters.topP == defaults.topP)
        #expect(parameters.topK == defaults.topK)
        #expect(parameters.repetitionPenalty == defaults.repetitionPenalty)
        #expect(
            parameters.repetitionContextSize
                == defaults.repetitionContextSize
        )
    }

    @Test
    func snapshotPolicyMatchesArchitectureAndAccessMode() {
        let commonPatterns = ["*.safetensors", "*.json", "*.txt"]

        #expect(MLXASRRuntime.snapshotPatterns(for: .qwen3) == commonPatterns)
        #expect(MLXASRRuntime.snapshotPatterns(for: .granite4) == commonPatterns)
        #expect(
            MLXASRRuntime.snapshotPatterns(for: .parakeetTDT)
                == commonPatterns
        )
        #expect(
            MLXASRRuntime.snapshotPatterns(for: .cohereTranscribe)
                == commonPatterns + ["*.model"]
        )
        #expect(
            !MLXASRRuntime.localFilesOnly(for: .downloadIfNeeded)
        )
        #expect(MLXASRRuntime.localFilesOnly(for: .localOnly))
    }

    @Test
    func transcriptionGateRejectsOverlapAndRecovers() throws {
        var gate = MLXASRTranscriptionGate()

        try gate.acquire()
        #expect(gate.isActive)
        #expect(throws: MLXASRRuntimeError.transcriptionInProgress) {
            try gate.acquire()
        }

        gate.release()
        #expect(!gate.isActive)
        try gate.acquire()
        #expect(gate.isActive)
    }

    @Test
    func qwenTokenizerGenerationIsLocalAndDeterministic() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data(#"{"hello":0,"world":1}"#.utf8).write(
            to: directory.appendingPathComponent("vocab.json")
        )
        try "#version: 0.2\nhello world\n".write(
            to: directory.appendingPathComponent("merges.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data(
            #"{"added_tokens_decoder":{"2":{"content":"<two>","special":true},"1":{"content":"<one>","special":true}}}"#
                .utf8
        ).write(to: directory.appendingPathComponent("tokenizer_config.json"))

        try StrictLocalASRModelLoader.generateQwenTokenizerJSONIfMissing(
            in: directory
        )

        let outputURL = directory.appendingPathComponent("tokenizer.json")
        let data = try Data(contentsOf: outputURL)
        let object = try JSONSerialization.jsonObject(with: data)
        let root = try #require(object as? [String: Any])
        let tokens = try #require(root["added_tokens"] as? [[String: Any]])
        let tokenIDs = tokens.compactMap { token in
            (token["id"] as? NSNumber)?.intValue
        }

        #expect(tokenIDs == [1, 2])
        #expect(root["model"] != nil)
        #expect(root["pre_tokenizer"] != nil)
    }
}
