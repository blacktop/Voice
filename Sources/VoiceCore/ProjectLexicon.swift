import Foundation

/// Errors produced while deriving speech-recognition vocabulary from a project directory.
public enum ProjectLexiconError: LocalizedError, Equatable, Sendable {
    case invalidProjectURL
    case projectDoesNotExist
    case projectIsNotDirectory

    public var errorDescription: String? {
        switch self {
        case .invalidProjectURL:
            "The selected project must be a local file URL."
        case .projectDoesNotExist:
            "The selected project does not exist."
        case .projectIsNotDirectory:
            "The selected project is not a directory."
        }
    }
}

/// Builds a bounded, local vocabulary from project file and directory names.
///
/// The scanner never opens file contents, does not follow symbolic links, and skips
/// hidden, generated, build, and vendored directories. Callers must explicitly pass
/// the project directory that is allowed to be scanned.
public struct ProjectLexicon: Sendable {
    public struct Configuration: Hashable, Sendable {
        /// The requested result limit. Values are clamped to Apple's 100-term context limit.
        public let maximumTerms: Int

        /// A work bound for unusually large repositories.
        public let maximumEntries: Int

        public init(maximumTerms: Int = 100, maximumEntries: Int = 25_000) {
            self.maximumTerms = min(max(maximumTerms, 0), 100)
            self.maximumEntries = max(maximumEntries, 0)
        }
    }

    private struct Candidate: Sendable {
        var term: String
        var score: Int
        var occurrences: Int
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Derives ranked contextual strings without reading any project file contents.
    public func contextualStrings(in selectedProjectURL: URL) async throws -> [String] {
        let configuration = configuration
        return try await Task(priority: .utility) { @concurrent in
            try Self.scan(selectedProjectURL, configuration: configuration)
        }.value
    }

    private static func scan(
        _ selectedProjectURL: URL,
        configuration: Configuration
    ) throws -> [String] {
        guard selectedProjectURL.isFileURL else {
            throw ProjectLexiconError.invalidProjectURL
        }

        let projectURL = selectedProjectURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let fileManager = FileManager()
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory) else {
            throw ProjectLexiconError.projectDoesNotExist
        }
        guard isDirectory.boolValue else {
            throw ProjectLexiconError.projectIsNotDirectory
        }
        guard configuration.maximumTerms > 0, configuration.maximumEntries > 0 else {
            return []
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .nameKey,
        ]
        guard
            let enumerator = fileManager.enumerator(
                at: projectURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            )
        else {
            throw ProjectLexiconError.projectIsNotDirectory
        }

        let excludedDirectories: Set<String> = [
            ".build", ".git", ".hg", ".svn", ".swiftpm",
            "__pycache__", "bazel-bin", "bazel-out", "bazel-testlogs", "bower_components",
            "buck-out", "build", "carthage", "coverage", "deriveddata", "dist",
            "node_modules", "out", "pods", "target", "third-party", "third_party",
            "vendor", "vendors", "venv",
        ]
        let ignoredTerms: Set<String> = [
            "assets", "build", "copying", "docs", "documentation", "examples",
            "include", "license", "node_modules", "package", "packages", "readme",
            "resources", "source", "sources", "test", "tests", "vendor",
        ]

        var candidates: [String: Candidate] = [:]
        var visitedEntries = 0

        while let itemURL = enumerator.nextObject() as? URL {
            guard visitedEntries < configuration.maximumEntries else {
                break
            }
            visitedEntries += 1

            guard isDescendant(itemURL, of: projectURL) else {
                continue
            }
            guard let values = try? itemURL.resourceValues(forKeys: keys) else {
                continue
            }

            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let name = values.name ?? itemURL.lastPathComponent
            let normalizedName = name.lowercased()
            let depth = max(itemURL.pathComponents.count - projectURL.pathComponents.count, 1)

            if values.isDirectory == true {
                if excludedDirectories.contains(normalizedName) {
                    enumerator.skipDescendants()
                    continue
                }

                add(name, baseScore: 64, depth: depth, ignoredTerms: ignoredTerms, to: &candidates)
                for part in identifierParts(from: name) {
                    add(
                        part, baseScore: 44, depth: depth, ignoredTerms: ignoredTerms,
                        to: &candidates)
                }
                continue
            }

            guard values.isRegularFile == true else {
                continue
            }

            add(name, baseScore: 120, depth: depth, ignoredTerms: ignoredTerms, to: &candidates)

            let stem = itemURL.deletingPathExtension().lastPathComponent
            add(stem, baseScore: 108, depth: depth, ignoredTerms: ignoredTerms, to: &candidates)
            for part in identifierParts(from: stem) {
                add(part, baseScore: 76, depth: depth, ignoredTerms: ignoredTerms, to: &candidates)
            }
        }

        return candidates.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.occurrences != rhs.occurrences {
                    return lhs.occurrences > rhs.occurrences
                }
                let lhsKey = lhs.term.lowercased()
                let rhsKey = rhs.term.lowercased()
                return lhsKey == rhsKey ? lhs.term < rhs.term : lhsKey < rhsKey
            }
            .prefix(configuration.maximumTerms)
            .map(\.term)
    }

    private static func isDescendant(_ itemURL: URL, of rootURL: URL) -> Bool {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let itemComponents = itemURL.standardizedFileURL.pathComponents
        guard itemComponents.count > rootComponents.count else {
            return false
        }
        return Array(itemComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func add(
        _ rawTerm: String,
        baseScore: Int,
        depth: Int,
        ignoredTerms: Set<String>,
        to candidates: inout [String: Candidate]
    ) {
        guard let term = sanitizedTerm(rawTerm) else {
            return
        }

        let key = term.lowercased()
        guard !ignoredTerms.contains(key) else {
            return
        }

        let depthBonus = max(12 - depth, 0)
        if var existing = candidates[key] {
            existing.occurrences += 1
            existing.score += min(max(baseScore / 5, 1), 20)
            if term < existing.term {
                existing.term = term
            }
            candidates[key] = existing
        } else {
            candidates[key] = Candidate(
                term: term,
                score: baseScore + depthBonus,
                occurrences: 1
            )
        }
    }

    private static func sanitizedTerm(_ rawTerm: String) -> String? {
        let term =
            rawTerm
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard (2...64).contains(term.count),
            term.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            return nil
        }
        return term
    }

    private static func identifierParts(from value: String) -> [String] {
        let chunks = value.split { character in
            !character.isLetter && !character.isNumber && character != "_"
        }
        var parts: [String] = []

        for chunk in chunks {
            let underscoreParts = chunk.split(separator: "_")
            for underscorePart in underscoreParts {
                let characters = Array(underscorePart)
                guard !characters.isEmpty else {
                    continue
                }

                var start = 0
                for index in 1..<characters.count {
                    let previous = characters[index - 1]
                    let current = characters[index]
                    let next = index + 1 < characters.count ? characters[index + 1] : nil
                    let startsWord =
                        current.isUppercase
                        && (previous.isLowercase || previous.isNumber || next?.isLowercase == true)
                    let changesNumericKind = current.isNumber != previous.isNumber

                    if startsWord || changesNumericKind {
                        parts.append(String(characters[start..<index]))
                        start = index
                    }
                }
                parts.append(String(characters[start...]))
            }
        }

        return parts
    }
}
