import Foundation

/// A launch command for an ACP agent already installed by Zed.
public struct ACPAgentLaunchChoice: Identifiable, Equatable, Sendable {
    public enum Agent: String, CaseIterable, Sendable {
        case claude
        case codex
    }

    public let id: String
    public let agent: Agent
    public let displayName: String
    public let executableURL: URL
    public let arguments: [String]
    public let sourceDescription: String

    init(
        agent: Agent,
        displayName: String,
        executableURL: URL,
        arguments: [String],
        sourceDescription: String
    ) {
        id = "zed-\(agent.rawValue)"
        self.agent = agent
        self.displayName = displayName
        self.executableURL = executableURL
        self.arguments = arguments
        self.sourceDescription = sourceDescription
    }
}

/// Finds Claude and Codex ACP launchers in Zed's documented macOS data directory.
///
/// Current registry agents distributed through npm live in Zed's isolated npm
/// cache. Older Zed releases also stored standalone binaries below
/// `external_agents`, so discovery keeps that layout as a fallback.
public struct ZedACPAgentDiscovery: Sendable {
    private enum CandidateSource: Int, Sendable {
        case externalAgent = 0
        case npmCache = 1

        var description: String {
            switch self {
            case .externalAgent:
                "Zed external agent"
            case .npmCache:
                "Zed ACP registry cache"
            }
        }
    }

    private struct Candidate: Sendable {
        let agent: ACPAgentLaunchChoice.Agent
        let launcherURL: URL
        let executableURL: URL
        let arguments: [String]
        let source: CandidateSource
        let modificationDate: Date
    }

    private let zedDataURL: URL

    public init() {
        let applicationSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        zedDataURL = applicationSupport.appendingPathComponent("Zed", isDirectory: true)
    }

    init(zedDataURL: URL) {
        self.zedDataURL = zedDataURL
    }

    public func discover() -> [ACPAgentLaunchChoice] {
        let fileManager = FileManager.default
        let nodeURL = newestNodeExecutable(fileManager: fileManager)
        var candidates = npmCacheCandidates(
            nodeURL: nodeURL,
            fileManager: fileManager
        )
        candidates.append(contentsOf: externalAgentCandidates(fileManager: fileManager))

        return ACPAgentLaunchChoice.Agent.allCases.compactMap { agent in
            guard
                let candidate =
                    candidates
                    .filter({ $0.agent == agent })
                    .max(by: Self.precedes)
            else {
                return nil
            }
            return ACPAgentLaunchChoice(
                agent: agent,
                displayName: agent == .claude ? "Claude Agent (Zed)" : "Codex ACP (Zed)",
                executableURL: candidate.executableURL,
                arguments: candidate.arguments,
                sourceDescription: candidate.source.description
            )
        }
    }

    private func npmCacheCandidates(
        nodeURL: URL?,
        fileManager: FileManager
    ) -> [Candidate] {
        let cacheURL =
            zedDataURL
            .appendingPathComponent("node/cache/_npx", isDirectory: true)
        guard
            let cacheDirectories = try? fileManager.contentsOfDirectory(
                at: cacheURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        let launchers: [(ACPAgentLaunchChoice.Agent, String)] = [
            (.claude, "claude-agent-acp"),
            (.codex, "codex-acp"),
        ]
        var candidates: [Candidate] = []
        for directory in cacheDirectories {
            for (agent, launcherName) in launchers {
                let launcherURL =
                    directory
                    .appendingPathComponent("node_modules/.bin", isDirectory: true)
                    .appendingPathComponent(launcherName)
                guard fileManager.isExecutableFile(atPath: launcherURL.path) else {
                    continue
                }

                let resolvedLauncher = launcherURL.resolvingSymlinksInPath()
                let executableURL = nodeURL ?? launcherURL
                let arguments = nodeURL == nil ? [] : [resolvedLauncher.path]
                candidates.append(
                    Candidate(
                        agent: agent,
                        launcherURL: launcherURL,
                        executableURL: executableURL,
                        arguments: arguments,
                        source: .npmCache,
                        modificationDate: modificationDate(
                            of: resolvedLauncher,
                            fileManager: fileManager
                        )
                    )
                )
            }
        }
        return candidates
    }

    private func externalAgentCandidates(fileManager: FileManager) -> [Candidate] {
        let externalAgentsURL =
            zedDataURL
            .appendingPathComponent("external_agents", isDirectory: true)
        let roots: [(ACPAgentLaunchChoice.Agent, String, String)] = [
            (.claude, "registry/claude-acp", "claude-agent-acp"),
            (.claude, "claude-agent-acp", "claude-agent-acp"),
            (.claude, "claude-code-acp", "claude-code-acp"),
            (.codex, "registry/codex-acp", "codex-acp"),
            (.codex, "codex-acp", "codex-acp"),
            (.codex, "codex", "codex-acp"),
        ]

        return roots.flatMap { agent, relativeRoot, executableName in
            namedExecutables(
                executableName,
                below: externalAgentsURL.appendingPathComponent(
                    relativeRoot,
                    isDirectory: true
                ),
                fileManager: fileManager
            ).map { executableURL in
                Candidate(
                    agent: agent,
                    launcherURL: executableURL,
                    executableURL: executableURL,
                    arguments: [],
                    source: .externalAgent,
                    modificationDate: modificationDate(
                        of: executableURL,
                        fileManager: fileManager
                    )
                )
            }
        }
    }

    private func namedExecutables(
        _ name: String,
        below rootURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        guard
            let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            return []
        }

        var results: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if enumerator.level > 5 {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == name,
                fileManager.isExecutableFile(atPath: url.path)
            else {
                continue
            }
            results.append(url)
        }
        return results
    }

    private func newestNodeExecutable(fileManager: FileManager) -> URL? {
        let nodeRoot = zedDataURL.appendingPathComponent("node", isDirectory: true)
        var managedCandidates: [URL] = []
        if let directories = try? fileManager.contentsOfDirectory(
            at: nodeRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            managedCandidates = directories.compactMap { directory in
                let nodeURL = directory.appendingPathComponent("bin/node")
                return fileManager.isExecutableFile(atPath: nodeURL.path) ? nodeURL : nil
            }
        }

        if let newestManaged = managedCandidates.max(by: { lhs, rhs in
            modificationDate(of: lhs, fileManager: fileManager)
                < modificationDate(of: rhs, fileManager: fileManager)
        }) {
            return newestManaged
        }

        return [
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/usr/bin/node"),
        ].first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func modificationDate(of url: URL, fileManager: FileManager) -> Date {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.modificationDate != rhs.modificationDate {
            return lhs.modificationDate < rhs.modificationDate
        }
        if lhs.source != rhs.source {
            return lhs.source.rawValue < rhs.source.rawValue
        }
        return lhs.launcherURL.path < rhs.launcherURL.path
    }
}
