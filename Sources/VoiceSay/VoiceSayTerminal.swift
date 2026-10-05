import Darwin
import Foundation

/// Owns /dev/tty, never stdin. All descriptor, termios, timer, and signal state
/// is confined to `queue`; start/stop synchronize with that queue. Signal and
/// timer handlers capture weakly, and stop cancels them before closing the fd.
final class VoiceSayTerminal: @unchecked Sendable {
    let spaces: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let queue = DispatchQueue(label: "io.blacktop.Voice.say.controls")
    private var descriptor: Int32 = -1
    private var original: termios?
    private var immediate: termios?
    private var inImmediateMode = false
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var restoreSignals: [() -> Void] = []

    init() {
        let pair = AsyncStream<Void>.makeStream()
        spaces = pair.stream
        continuation = pair.continuation
    }

    /// A background job or a process without a controlling terminal gets no
    /// controls. stdin may be a pipe: its document bytes are never consumed here.
    func start() -> Bool {
        queue.sync {
            guard descriptor < 0 else { return true }
            let fd = Darwin.open("/dev/tty", O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return false }
            guard isatty(fd) == 1, tcgetpgrp(fd) == getpgrp() else {
                Darwin.close(fd)
                return false
            }
            var saved = termios()
            guard tcgetattr(fd, &saved) == 0 else {
                Darwin.close(fd)
                return false
            }
            descriptor = fd
            original = saved
            var mode = saved
            mode.c_lflag &= ~tcflag_t(ICANON | ECHO)
            withUnsafeMutableBytes(of: &mode.c_cc) { bytes in
                bytes[Int(VMIN)] = 0
                bytes[Int(VTIME)] = 0
            }
            immediate = mode

            // Restoration must also work if the shell backgrounds the process.
            let previousTTOU = signal(SIGTTOU, SIG_IGN)
            restoreSignals.append { signal(SIGTTOU, previousTTOU) }
            for number in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGTSTP] {
                let previous = signal(number, SIG_IGN)
                restoreSignals.append { signal(number, previous) }
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.handleSignal(number) }
                signals.append(source)
                source.resume()
            }
            guard setImmediateMode() else {
                closeOnQueue()
                return false
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(40))
            timer.setEventHandler { [weak self] in self?.readKeys() }
            self.timer = timer
            timer.resume()
            return true
        }
    }

    func stop() {
        queue.sync { closeOnQueue() }
    }

    deinit {
        // No other strong reference can be using this state during deinit;
        // deinit can run on queue after a weak event handler releases self.
        closeOnQueue()
    }

    private func setImmediateMode() -> Bool {
        guard !inImmediateMode else { return true }
        guard var mode = immediate, tcsetattr(descriptor, TCSANOW, &mode) == 0 else { return false }
        inImmediateMode = true
        return true
    }

    private func restoreMode() {
        guard inImmediateMode, var saved = original else { return }
        _ = tcsetattr(descriptor, TCSANOW, &saved)
        inImmediateMode = false
    }

    private func readKeys() {
        guard descriptor >= 0 else { return }
        guard tcgetpgrp(descriptor) == getpgrp() else {
            restoreMode()
            return
        }
        guard setImmediateMode() else { return }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            for byte in bytes.prefix(count) where byte == 32 { continuation.yield(()) }
        }
    }

    private func handleSignal(_ number: Int32) {
        guard descriptor >= 0 else { return }
        restoreMode()
        if number == SIGTSTP {
            // SIGSTOP cannot be swallowed by our dispatch signal source. On
            // foreground continuation the timer restores immediate input mode.
            kill(getpid(), SIGSTOP)
        } else {
            closeOnQueue()
            signal(number, SIG_DFL)
            raise(number)
            Darwin._exit(128 + number)
        }
    }

    private func closeOnQueue() {
        timer?.cancel()
        timer = nil
        for source in signals { source.cancel() }
        signals.removeAll()
        restoreMode()
        for restore in restoreSignals { restore() }
        restoreSignals.removeAll()
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        continuation.finish()
    }
}
