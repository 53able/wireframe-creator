import Foundation

enum RuntimeToolFailure: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            "必要なコマンド「\(name)」が見つかりません。インストール状態を確認してください。"
        }
    }
}

enum RuntimeTools {
    private static var searchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)].compactMap { $0 }
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }

        let nvm = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            paths += versions.sorted {
                $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
            }.map { $0.appendingPathComponent("bin", isDirectory: true) }
        }
        paths += [
            home.appendingPathComponent(".volta/bin", isDirectory: true),
            home.appendingPathComponent(".local/bin", isDirectory: true),
            home.appendingPathComponent(".bun/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true)
        ]
        var seen = Set<String>()
        return paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func find(_ name: String) throws -> URL {
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw RuntimeToolFailure.missing(name)
    }

    static func environment(prepending directory: URL? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var directories = searchDirectories
        if let directory { directories.insert(directory, at: 0) }
        var seen = Set<String>()
        environment["PATH"] = directories.map(\.path).filter { seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }
}

/// 子プロセスの実行をSwift Concurrencyの協調スレッドを塞がずに待つための共通ヘルパー。
///
/// `waitUntilExit()` や `readDataToEndOfFile()` を同期的に呼ぶと、呼び出したスレッドが
/// プロセス終了まで戻らない。協調スレッドプールの幅はコア数相当で固定されているため、
/// 同時実行数がコア数に達すると他のTaskがスレッドを取得できなくなる。
/// ここでは `terminationHandler` と `readabilityHandler` / `writeabilityHandler`
/// （いずれもDispatch管理の別キューから呼ばれる）だけを使い、同期ブロッキングを排除する。
enum ProcessRunner {
    struct Outcome: Sendable {
        let output: Data
        let terminationStatus: Int32
        let terminationReason: Process.TerminationReason
    }

    /// 標準出力の読み込み完了（EOF）とプロセス終了の両方が揃った時点だけでcontinuationを解決する状態機械。
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var readingFinished = false
        private var exited = false
        private var status: Int32 = 0
        private var reason: Process.TerminationReason = .exit
        private var continuation: CheckedContinuation<Outcome, Error>?
        private var resolved = false

        func attach(_ continuation: CheckedContinuation<Outcome, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            resolveIfReady()
        }

        func append(_ data: Data) {
            lock.lock()
            buffer.append(data)
            lock.unlock()
        }

        func markReadingFinished() {
            lock.lock()
            readingFinished = true
            lock.unlock()
            resolveIfReady()
        }

        func markExited(status: Int32, reason: Process.TerminationReason) {
            lock.lock()
            exited = true
            self.status = status
            self.reason = reason
            lock.unlock()
            resolveIfReady()
        }

        private func resolveIfReady() {
            lock.lock()
            guard !resolved, readingFinished, exited, let pending = continuation else {
                lock.unlock()
                return
            }
            resolved = true
            continuation = nil
            let outcome = Outcome(output: buffer, terminationStatus: status, terminationReason: reason)
            lock.unlock()
            pending.resume(returning: outcome)
        }
    }

    private final class WriteCursor: @unchecked Sendable {
        private let lock = NSLock()
        private let data: Data
        private var offset = 0

        init(_ data: Data) { self.data = data }

        func next(_ limit: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard offset < data.count else { return nil }
            let end = min(offset + limit, data.count)
            let chunk = data.subdata(in: offset..<end)
            offset = end
            return chunk
        }
    }

    /// `register` → `run()` → `didStart` → `unregister` の順序と意味は同期版と同じ。
    /// `cancellation.cancel()` はプロセスを `terminate()` するため、必ず `terminationHandler`
    /// が発火し、continuationは解決される（宙に浮かない）。
    static func run(
        _ process: Process,
        output: Pipe,
        input: (pipe: Pipe, data: Data)? = nil,
        cancellation: JobCancellation
    ) async throws -> Outcome {
        let state = State()
        let readHandle = output.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                state.markReadingFinished()
            } else {
                state.append(chunk)
            }
        }
        process.terminationHandler = { finished in
            state.markExited(status: finished.terminationStatus, reason: finished.terminationReason)
        }

        try cancellation.register(process)
        defer { cancellation.unregister(process) }
        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            process.terminationHandler = nil
            throw error
        }
        do {
            // 起動直後にキャンセル済みなら didStart が terminate + wait して投げる。
            // continuationはまだ作っていないので取りこぼしは起きない。
            try cancellation.didStart(process)
        } catch {
            readHandle.readabilityHandler = nil
            throw error
        }

        if let input { writeAndClose(input.pipe.fileHandleForWriting, data: input.data) }

        let outcome = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.attach(continuation)
            }
        } onCancel: {
            cancellation.cancel()
        }
        try cancellation.check()
        return outcome
    }

    /// プロンプト全文を一度に同期書き込みすると、子プロセスが先に大量の標準出力を吐いた場合に
    /// 双方がブロックして永久にハングする。チャンク単位の非同期書き込みで読み書きを並行させる。
    private static func writeAndClose(_ handle: FileHandle, data: Data) {
        guard !data.isEmpty else {
            try? handle.close()
            return
        }
        let cursor = WriteCursor(data)
        handle.writeabilityHandler = { writable in
            guard let chunk = cursor.next(8192) else {
                writable.writeabilityHandler = nil
                try? writable.close()
                return
            }
            do {
                try writable.write(contentsOf: chunk)
            } catch {
                writable.writeabilityHandler = nil
                try? writable.close()
            }
        }
    }
}

/// pi CLIの `--mode rpc` 用の双方向JSON Linesセッション。
///
/// `ProcessRunner` は「入力を書き切り、出力を読み切って終了を待つ」単発リクエスト向けで、
/// 応答を見てから追加入力を送るRPCモードには使えない。ここでも `waitUntilExit()` や
/// `readDataToEndOfFile()` は使わず、`readabilityHandler` と `terminationHandler`、
/// および専用のシリアルキューだけで読み書きする。
final class RPCSession: @unchecked Sendable {
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let writeQueue = DispatchQueue(label: "agent-workspace.rpc-session.write")
    private let lock = NSLock()
    private var buffer = Data()
    private var exited = false
    private var status: Int32 = 0
    private var reason: Process.TerminationReason = .exit
    private var exitContinuation: CheckedContinuation<(status: Int32, reason: Process.TerminationReason), Never>?
    private let continuation: AsyncStream<String>.Continuation

    /// 子プロセスの標準出力を1行ずつ（LF区切りのみ、末尾の `\r` は除去）流すストリーム。
    let lines: AsyncStream<String>

    init(process: Process, input: Pipe, output: Pipe) {
        self.process = process
        self.input = input
        self.output = output
        var sink: AsyncStream<String>.Continuation!
        lines = AsyncStream(bufferingPolicy: .unbounded) { sink = $0 }
        continuation = sink
    }

    func start(cancellation: JobCancellation) throws {
        let readHandle = output.fileHandleForReading
        readHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self?.finishLines()
            } else {
                self?.append(chunk)
            }
        }
        process.terminationHandler = { [weak self] finished in
            self?.markExited(status: finished.terminationStatus, reason: finished.terminationReason)
        }
        try cancellation.register(process)
        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.finish()
            throw error
        }
        do {
            try cancellation.didStart(process)
        } catch {
            readHandle.readabilityHandler = nil
            continuation.finish()
            throw error
        }
    }

    /// 1件のJSONコマンドを標準入力へ書き込む。書き込みは専用キューで行い協調スレッドを塞がない。
    func send(_ command: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: command, options: [.withoutEscapingSlashes]) else { return }
        let handle = input.fileHandleForWriting
        writeQueue.async {
            var line = data
            line.append(0x0A)
            try? handle.write(contentsOf: line)
        }
    }

    /// 標準入力を閉じる。pi はEOFを受け取ると終了コード0で正常終了する。
    func closeInput() {
        let handle = input.fileHandleForWriting
        writeQueue.async { try? handle.close() }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    @discardableResult
    func waitForExit() async -> (status: Int32, reason: Process.TerminationReason) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(status: Int32, reason: Process.TerminationReason), Never>) in
            lock.lock()
            if exited {
                let outcome = (status: status, reason: reason)
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                exitContinuation = continuation
                lock.unlock()
            }
        }
    }

    private func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var records: [String] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            var record = buffer.subdata(in: buffer.startIndex..<index)
            buffer = buffer.subdata(in: buffer.index(after: index)..<buffer.endIndex)
            if record.last == 0x0D { record.removeLast() }
            records.append(String(decoding: record, as: UTF8.self))
        }
        lock.unlock()
        for record in records where !record.isEmpty { continuation.yield(record) }
    }

    private func finishLines() {
        lock.lock()
        let rest = buffer
        buffer = Data()
        lock.unlock()
        let tail = String(decoding: rest, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { continuation.yield(tail) }
        continuation.finish()
    }

    private func markExited(status: Int32, reason: Process.TerminationReason) {
        lock.lock()
        exited = true
        self.status = status
        self.reason = reason
        let pending = exitContinuation
        exitContinuation = nil
        lock.unlock()
        pending?.resume(returning: (status: status, reason: reason))
    }
}

enum WorkspaceResources {
    static var repository: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--repo-root"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
        }
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("builder/build-wireframe.mjs").path) {
            return resources
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).standardizedFileURL
    }
}
