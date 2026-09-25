import Foundation

struct BuildResult: Sendable {
    let artifactURL: URL
    let transcript: String
}

enum BuildFailure: LocalizedError {
    case missingRepository(URL)
    case commandFailed(String, Int32, String)
    case noAvailableFilename

    var errorDescription: String? {
        switch self {
        case .missingRepository(let root):
            "Markoビルダーが見つかりません: \(root.path)"
        case .commandFailed(let label, let code, let output):
            "\(label)が失敗しました（終了コード \(code)）。\n\(output)"
        case .noAvailableFilename:
            "未使用の成果物ファイル名を確保できませんでした。"
        }
    }
}

enum BuildService {
    static func build(json: String, sourceName: String, outputDirectory: URL, repository: URL, cancellation: JobCancellation) throws -> BuildResult {
        try cancellation.check()
        let builder = repository.appendingPathComponent("builder/build-wireframe.mjs")
        let validator = repository.appendingPathComponent("scripts/validate-wireframe.py")
        guard FileManager.default.fileExists(atPath: builder.path),
              FileManager.default.fileExists(atPath: validator.path) else {
            throw BuildFailure.missingRepository(repository)
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("agent-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let input = temporary.appendingPathComponent("input.json")
        let draft = temporary.appendingPathComponent("draft.html")
        try json.write(to: input, atomically: true, encoding: .utf8)

        let node = try RuntimeTools.find("node")
        let python = try RuntimeTools.find("python3")
        let minScreens = String(max(1, WireframeReviewSpec.read(json)?.screens.count ?? 1))
        let buildLog = try run(node, [builder.path, input.path, draft.path], in: repository, label: "Markoビルド", cancellation: cancellation)
        let validationLog = try run(python, [validator.path, draft.path, "--min-screens", minScreens, "--require-actions"], in: repository, label: "構造検証", cancellation: cancellation)

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let slug = slugify(sourceName)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current

        for _ in 0..<1000 {
            try cancellation.check()
            let name = "\(slug)-wireframe-\(formatter.string(from: Date())).html"
            let artifact = outputDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: artifact.path) {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            do {
                try FileManager.default.copyItem(at: draft, to: artifact)
                do {
                    let finalLog = try run(python, [validator.path, artifact.path, "--min-screens", minScreens, "--require-actions"], in: repository, label: "正本検証", cancellation: cancellation)
                    try cancellation.check()
                    return BuildResult(artifactURL: artifact, transcript: [buildLog, validationLog, finalLog].joined(separator: "\n"))
                } catch {
                    try? FileManager.default.removeItem(at: artifact)
                    throw error
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        throw BuildFailure.noAvailableFilename
    }

    private static func run(_ executable: URL, _ arguments: [String], in directory: URL, label: String, cancellation: JobCancellation) throws -> String {
        try cancellation.check()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = RuntimeTools.environment(prepending: executable.deletingLastPathComponent())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try cancellation.register(process)
        defer { cancellation.unregister(process) }
        try process.run()
        try cancellation.didStart(process)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try cancellation.check()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw BuildFailure.commandFailed(label, process.terminationStatus, output)
        }
        return "\(label): \(output)"
    }

    private static func slugify(_ name: String) -> String {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.lowercased()
        let slug = stem.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "workspace" : slug
    }
}
