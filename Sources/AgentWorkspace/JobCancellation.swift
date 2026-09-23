import Foundation

/// Keeps a subprocess from advancing a suspended project after provider logout.
final class JobCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func check() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped { throw CancellationError() }
    }

    func register(_ process: Process) throws {
        lock.lock()
        let stopped = cancelled
        if !stopped { self.process = process }
        lock.unlock()
        if stopped { throw CancellationError() }
    }

    func didStart(_ process: Process) throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw CancellationError()
        }
    }

    func unregister(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }
}
