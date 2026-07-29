import ArgumentParser

/// Entry point kept separate from the command so `VoiceSay` itself can be
/// compiled into the test target; `@main` is not allowed in a test bundle.
@main
struct VoiceSayMain {
    static func main() async {
        await VoiceSay.main()
    }
}
