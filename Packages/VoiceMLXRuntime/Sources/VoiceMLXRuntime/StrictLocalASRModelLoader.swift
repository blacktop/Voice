import Foundation
internal import Hub
@preconcurrency internal import MLX
internal import MLXAudioSTT
internal import MLXLMCommon
internal import MLXNN
internal import Tokenizers

enum StrictLocalASRModelLoader {
    static func loadQwen3(
        from modelDirectory: URL
    ) async throws -> Qwen3ASRModel {
        let configData = try Data(
            contentsOf: modelDirectory.appendingPathComponent("config.json")
        )
        let config = try JSONDecoder().decode(Qwen3ASRConfig.self, from: configData)
        let model = Qwen3ASRModel(config)

        try generateQwenTokenizerJSONIfMissing(in: modelDirectory)
        model.tokenizer = try await strictLocalTokenizer(from: modelDirectory)

        let weights = try loadSafetensorWeights(from: modelDirectory)
        let sanitizedWeights = Qwen3ASRModel.sanitize(
            weights: weights,
            skipLmHead: config.textConfig.tieWordEmbeddings
        )
        if let perLayerQuantization = config.perLayerQuantization {
            quantize(model: model) { path, _ in
                guard !path.hasPrefix("audio_tower") else { return nil }
                guard sanitizedWeights["\(path).scales"] != nil else { return nil }
                return perLayerQuantization.quantization(layer: path)?.asTuple
            }
        }
        try model.update(
            parameters: ModuleParameters.unflattened(sanitizedWeights),
            verify: .all
        )
        eval(model)
        return model
    }

    static func loadGranite(
        from modelDirectory: URL
    ) async throws -> GraniteSpeechModel {
        let configData = try Data(
            contentsOf: modelDirectory.appendingPathComponent("config.json")
        )
        let config = try JSONDecoder().decode(
            GraniteSpeechModelConfig.self,
            from: configData
        )
        let model = GraniteSpeechModel(config)
        model.tokenizer = try await strictLocalTokenizer(from: modelDirectory)

        let weights = try loadSafetensorWeights(from: modelDirectory)
        let sanitizedWeights = GraniteSpeechModel.sanitize(weights: weights)
        if let perLayerQuantization = config.perLayerQuantization {
            quantize(model: model) { path, _ in
                guard sanitizedWeights["\(path).scales"] != nil else { return nil }
                return perLayerQuantization.quantization(layer: path)?.asTuple
            }
        }
        try model.update(
            parameters: ModuleParameters.unflattened(sanitizedWeights),
            verify: .all
        )
        eval(model)
        return model
    }

    // Mirrors the MIT-licensed mlx-audio-swift 0.1.3 local Qwen factory solely
    // so Voice can inject an explicit offline HubApi into tokenizer loading.
    static func generateQwenTokenizerJSONIfMissing(
        in modelDirectory: URL
    ) throws {
        let tokenizerJSONURL = modelDirectory.appendingPathComponent(
            "tokenizer.json"
        )
        guard !FileManager.default.fileExists(atPath: tokenizerJSONURL.path) else {
            return
        }

        let vocabURL = modelDirectory.appendingPathComponent("vocab.json")
        let mergesURL = modelDirectory.appendingPathComponent("merges.txt")
        let tokenizerConfigURL = modelDirectory.appendingPathComponent(
            "tokenizer_config.json"
        )
        guard FileManager.default.fileExists(atPath: vocabURL.path),
            FileManager.default.fileExists(atPath: mergesURL.path)
        else {
            return
        }

        let vocabData = try Data(contentsOf: vocabURL)
        let mergesText = try String(contentsOf: mergesURL, encoding: .utf8)
        let mergeLines = mergesText.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
        let mergesJSON = mergeLines.map { line in
            let escaped =
                line
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: ",")

        var addedTokensJSON = "[]"
        if FileManager.default.fileExists(atPath: tokenizerConfigURL.path) {
            let configData = try Data(contentsOf: tokenizerConfigURL)
            if let config = try JSONSerialization.jsonObject(with: configData)
                as? [String: Any],
                let decoder = config["added_tokens_decoder"] as? [String: Any]
            {
                var tokens: [(Int, [String: Any])] = []
                for (idString, value) in decoder {
                    guard let id = Int(idString),
                        let token = value as? [String: Any]
                    else {
                        continue
                    }
                    tokens.append(
                        (
                            id,
                            [
                                "id": id,
                                "content": token["content"] ?? "",
                                "single_word": token["single_word"] ?? false,
                                "lstrip": token["lstrip"] ?? false,
                                "rstrip": token["rstrip"] ?? false,
                                "normalized": token["normalized"] ?? false,
                                "special": token["special"] ?? false,
                            ]
                        )
                    )
                }
                tokens.sort { $0.0 < $1.0 }
                let tokenData = try JSONSerialization.data(
                    withJSONObject: tokens.map { $0.1 }
                )
                addedTokensJSON = String(data: tokenData, encoding: .utf8) ?? "[]"
            }
        }

        let preTokenizerPattern =
            "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|"
            + "\\p{N}{1,3}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|"
            + "\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
        let escapedPattern =
            preTokenizerPattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let vocabString = String(data: vocabData, encoding: .utf8) ?? "{}"
        let tokenizerJSON = """
            {
              "version": "1.0",
              "truncation": null,
              "padding": null,
              "added_tokens": \(addedTokensJSON),
              "normalizer": {"type": "NFC"},
              "pre_tokenizer": {
                "type": "Sequence",
                "pretokenizers": [
                  {
                    "type": "Split",
                    "pattern": {"Regex": "\(escapedPattern)"},
                    "behavior": "Isolated",
                    "invert": false
                  },
                  {
                    "type": "ByteLevel",
                    "add_prefix_space": false,
                    "trim_offsets": true,
                    "use_regex": false
                  }
                ]
              },
              "post_processor": null,
              "decoder": {
                "type": "ByteLevel",
                "add_prefix_space": true,
                "trim_offsets": true,
                "use_regex": true
              },
              "model": {
                "type": "BPE",
                "dropout": null,
                "unk_token": null,
                "continuing_subword_prefix": "",
                "end_of_word_suffix": "",
                "fuse_unk": false,
                "byte_fallback": false,
                "vocab": \(vocabString),
                "merges": [\(mergesJSON)]
              }
            }
            """
        try tokenizerJSON.write(
            to: tokenizerJSONURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func strictLocalTokenizer(
        from modelDirectory: URL
    ) async throws -> Tokenizers.Tokenizer {
        let hubApi = HubApi(
            downloadBase: modelDirectory,
            cache: nil,
            hfToken: "",
            endpoint: "https://huggingface.co",
            useBackgroundSession: false,
            useOfflineMode: true
        )
        return try await AutoTokenizer.from(
            modelFolder: modelDirectory,
            hubApi: hubApi,
            strict: true
        )
    }

    private static func loadSafetensorWeights(
        from modelDirectory: URL
    ) throws -> [String: MLXArray] {
        let files = try FileManager.default.contentsOfDirectory(
            at: modelDirectory,
            includingPropertiesForKeys: nil
        )
        var weights: [String: MLXArray] = [:]
        for file in files where file.pathExtension == "safetensors" {
            let shard = try MLX.loadArrays(url: file)
            weights.merge(shard) { _, new in new }
        }
        return weights
    }
}
