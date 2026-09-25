import Foundation

struct AgentSkill: Identifiable, Sendable {
    let name: String
    let description: String
    let fileURL: URL

    var id: String { fileURL.path }
}

enum AgentSkillCommand {
    case ordinary
    case selected(AgentSkill, arguments: String)
    case unknown(String)
}

enum AgentSkillCatalog {
    private struct Record: Decodable {
        let name: String
        let description: String
        let filePath: String
    }

    static func discover() throws -> [AgentSkill] {
        let repository = WorkspaceResources.repository
        let script = repository.appendingPathComponent("scripts/skill-catalog.mjs")
        guard FileManager.default.fileExists(atPath: script.path) else { throw RuntimeToolFailure.missing("スキル一覧コンポーネント") }
        let node = try RuntimeTools.find("node")
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]
        process.currentDirectoryURL = repository
        process.environment = RuntimeTools.environment(prepending: node.deletingLastPathComponent())
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PiChatFailure.commandFailed(process.terminationStatus, detail)
        }
        return try JSONDecoder().decode([Record].self, from: data)
            .map { AgentSkill(name: $0.name, description: $0.description, fileURL: URL(fileURLWithPath: $0.filePath)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func resolve(_ input: String, among skills: [AgentSkill]) -> AgentSkillCommand {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .ordinary }
        let body = trimmed.dropFirst()
        let command = String(body.prefix(while: { !$0.isWhitespace }))
        let name = command.hasPrefix("skill:") ? String(command.dropFirst(6)) : command
        guard let skill = skills.first(where: { $0.name == name }) else { return .unknown(name) }
        let arguments = String(body.dropFirst(command.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .selected(skill, arguments: arguments)
    }
}
