import Foundation

public struct VoicePlatformCapabilities: Sendable {
    public let operatingSystemMajorVersion: Int
    public let runsOnMacOS27OrLater: Bool
    public let hasCompiledMacOS27Adapters: Bool

    public static var current: VoicePlatformCapabilities {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return VoicePlatformCapabilities(
            operatingSystemMajorVersion: major,
            runsOnMacOS27OrLater: major >= 27,
            // AnalyzerInputConversion wraps AnalyzerInputConverter, a macOS 27
            // API, and is compiled against the macOS 27 SDK.
            hasCompiledMacOS27Adapters: true
        )
    }
}
