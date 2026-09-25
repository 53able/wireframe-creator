import Foundation

struct OperationCapability: Codable, Identifiable, Sendable {
    let id: String
    let screenId: String
    let label: String
    let expectedResult: String?
    let status: String
    let reason: String

    var statusLabel: String {
        switch status {
        case "working": return "動作する"
        case "navigation-only": return "画面遷移のみ"
        case "display-only": return "表示のみ"
        case "unsupported": return "未対応"
        default: return status
        }
    }

    var symbolName: String {
        switch status {
        case "working": return "checkmark.circle.fill"
        case "unsupported": return "xmark.circle.fill"
        case "navigation-only", "display-only": return "minus.circle.fill"
        default: return "questionmark.circle"
        }
    }
}

struct OperationCapabilityReport: Codable, Sendable {
    let version: Int
    let sourceDigest: String
    let operations: [OperationCapability]
    let declaredCount: Int?

    var isFreeform: Bool { (declaredCount ?? 0) == 0 }
    var unsupportedCount: Int { operations.filter { $0.status == "unsupported" }.count }
}

enum OperationCapabilityService {
    enum Failure: LocalizedError {
        case missingScript(URL)
        case commandFailed(Int32, String)
        case invalidOutput(String)

        var errorDescription: String? {
            switch self {
            case .missingScript(let url): return "操作解析スクリプトが見つかりません: \(url.path)"
            case .commandFailed(let code, let output): return "操作解析に失敗しました（終了コード \(code)）。\n\(output)"
            case .invalidOutput(let output): return "操作解析の結果を読み取れませんでした。\n\(output)"
            }
        }
    }

    static func analyze(json: String, repository: URL, cancellation: JobCancellation) async throws -> OperationCapabilityReport {
        try cancellation.check()
        let script = repository.appendingPathComponent("builder/analyze-operations.mjs")
        guard FileManager.default.fileExists(atPath: script.path) else { throw Failure.missingScript(script) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agent-workspace-operation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("input.json")
        try json.write(to: input, atomically: true, encoding: .utf8)

        let node = try RuntimeTools.find("node")
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path, input.path]
        process.currentDirectoryURL = repository
        process.environment = RuntimeTools.environment(prepending: node.deletingLastPathComponent())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let outcome = try await ProcessRunner.run(process, output: pipe, cancellation: cancellation)
        let output = String(decoding: outcome.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard outcome.terminationReason == .exit, outcome.terminationStatus == 0 else {
            throw Failure.commandFailed(outcome.terminationStatus, output)
        }
        guard let result = output.data(using: .utf8), let report = try? JSONDecoder().decode(OperationCapabilityReport.self, from: result) else {
            throw Failure.invalidOutput(output)
        }
        guard report.version == 1, report.sourceDigest.count == 64 else { throw Failure.invalidOutput(output) }
        return report
    }
}
