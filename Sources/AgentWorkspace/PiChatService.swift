import Foundation

struct ChatMessage: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    let attachments: [ChatImageAttachment]

    init(role: Role, text: String, attachments: [ChatImageAttachment] = []) {
        id = UUID()
        self.role = role
        self.text = text
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, attachments }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        attachments = try container.decodeIfPresent([ChatImageAttachment].self, forKey: .attachments) ?? []
    }
}

enum PiChatFailure: LocalizedError {
    case emptyResponse
    case invalidDraft(String)
    case commandFailed(Int32, String)
    case approvalUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            "モデルから応答がありませんでした。接続状態を確認してください。"
        case .invalidDraft(let response):
            "仕様案をJSONとして読めませんでした。\n\(response)"
        case .commandFailed(let code, let output):
            "モデルの応答に失敗しました（終了コード \(code)）。\n\(output)"
        case .approvalUnavailable:
            "スキルの操作確認を利用できません。実行を中止しました。"
        }
    }
}

struct SkillToolApproval: Identifiable, Sendable {
    let id: String
    let toolName: String
    let arguments: String
}

enum PiChatService {
    private static let conversationSystemPrompt = """
        あなたはワイヤーフレーム作成を支援するプロダクト設計者です。日本語で簡潔に会話してください。
        対象ユーザー、解決する課題、主要な操作、検証したい仮説を整理します。
        対象ユーザー、主要フロー、検証目的が変わる不明点だけをまとめて質問してください。候補の仮データや文言などの細部は仮定として進めてください。
        資料にない調査結果やユーザー反応を作らないでください。
        画面の実装コードやJSONは、求められるまで出力しないでください。
        """

    static func reply(to messages: [ChatMessage], currentDraft: String?, model: String, repository: URL, cancellation: JobCancellation, skill: AgentSkill? = nil, skillArguments: String = "", workingDirectory: URL? = nil, approveTool: (@Sendable (SkillToolApproval) async -> Bool)? = nil) throws -> String {
        var prompt: String
        let systemPrompt: String
        if let skill {
            let earlierMessages = Array(messages.dropLast())
            prompt = "/skill:\(skill.name) 利用者の依頼: \(skillArguments.isEmpty ? "このスキルを使ってください。必要な入力があれば質問してください。" : skillArguments)"
            if !earlierMessages.isEmpty { prompt += "\n\n会話履歴:\n\(transcript(earlierMessages))" }
            if let currentDraft, !currentDraft.isEmpty { prompt += "\n\n現在レビュー中の画面仕様JSON:\n\(currentDraft)" }
            systemPrompt = "利用者が指定したエージェントスキルを読み、その手順に従ってください。結果と実行した操作を日本語で簡潔に報告してください。"
        } else {
            prompt = transcript(messages)
            if let currentDraft, !currentDraft.isEmpty {
                prompt += "\n現在レビュー中の画面仕様JSON:\n\(currentDraft)\n"
            }
            prompt += "\n直近の利用者の発言に答えてください。重要な判断が残る場合だけ質問してください。"
            systemPrompt = conversationSystemPrompt
        }
        return try invoke(prompt: prompt, systemPrompt: systemPrompt, model: model, repository: repository, cancellation: cancellation, skill: skill, workingDirectory: workingDirectory, approveTool: approveTool, images: contextImages(messages))
    }

    static func proposeDraft(from messages: [ChatMessage], currentDraft: String?, model: String, repository: URL, cancellation: JobCancellation) throws -> String {
        let example = try String(contentsOf: repository.appendingPathComponent("examples/wireframe.json"), encoding: .utf8)
        var prompt = transcript(messages)
        if let currentDraft, !currentDraft.isEmpty {
            prompt += "\n前回の画面仕様JSON。変更指示に関係する箇所だけを修正してください:\n\(currentDraft)\n"
        }
        prompt += """

            上の会話に基づいて、操作可能な低忠実度ワイヤーフレームの仕様JSONを作成してください。
            次のJSONと同じ基本キー、型、block.type、action.variantを使ってください。画面は学習目的に必要な1〜3枚に絞ってください。
            各screenにoperations配列を追加し、検証したい主要な操作を記述してください。各要素はid、label、kind、triggerRef、必要ならtargetRefとexpectedResultを持ちます。kindはnavigate、reflect-value、static-display、save、content-switchのいずれかです。
            actionには安定したidを付けてください。operationsのtriggerRefにはaction.idまたはfield/selectのkeyを指定します。content-switchのtargetRefには対象panelのidを指定し、panelにもidを付けてください。
            例: {"id":"tone-changes-body","label":"語り口で本文が変わる","kind":"content-switch","triggerRef":"tone","targetRef":"diary-body","expectedResult":"選んだ語り口の本文に変わる"}。
            「保存する」という操作は画面遷移だけでは保存になりません。期待する保存動作はkindをsaveとして明記してください。実装済みかどうかの判定値は出力しないでください。
            全action.targetは存在するscreen.idへ向け、少なくとも一つの画面遷移を含めてください。
            選択した値を確認画面に表示する場合、selectまたはfieldのkeyとvalueブロックのkeyを同じにしてください。
            screen.idとblock.keyは小文字英字で始め、続きは小文字英数字とハイフンだけを使ってください。大文字やアンダースコアは使えません。
            fieldブロックのinputTypeはtext、textarea、email、number、search、date、time、datetime-local、tel、urlのいずれかにしてください。日記本文など複数行の入力にはtextareaを使います。
            fieldブロックを使う場合の例: {"type":"field","key":"diary-body","label":"日記本文","inputType":"textarea","placeholder":"今日の出来事を書いてください"}。inputTypeを省略しないでください。
            paletteはslate、indigo、tealのいずれかにしてください。grayやgreyは使わず、グレー系にはslateを使います。
            仮の日時は過去の日付を使わず、曜日や相対表現にしてください。実データとして見せないでください。
            不明なことを事実として書かず、必要ならassumptionsとopenQuestionsへ短く記載してください。
            JSONオブジェクトだけを返し、コードフェンスや説明文を付けないでください。

            形式例:
            \(example)
            """
        let raw = try invoke(
            prompt: prompt,
            systemPrompt: "あなたはワイヤーフレーム仕様をJSONで出力する設計者です。指定されたスキーマを厳守し、説明文を出力しません。",
            model: model,
            repository: repository,
            cancellation: cancellation,
            images: contextImages(messages)
        )
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.hasPrefix("```"), let first = trimmed.firstIndex(of: "\n"), let end = trimmed.range(of: "```", options: .backwards) {
            candidate = String(trimmed[trimmed.index(after: first)..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            candidate = trimmed
        }
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any],
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: pretty, encoding: .utf8) else {
            throw PiChatFailure.invalidDraft(String(raw.prefix(1200)))
        }
        return text + "\n"
    }

    private static func transcript(_ messages: [ChatMessage]) -> String {
        messages.map { message in
            let names = message.attachments.map(\.name).joined(separator: "、")
            return "\(message.role == .user ? "利用者" : "アシスタント"): \(message.text)\(names.isEmpty ? "" : " [添付画像: \(names)]")"
        }.joined(separator: "\n\n")
    }

    private static func contextImages(_ messages: [ChatMessage]) -> [ChatImageAttachment] {
        Array(messages.filter { $0.role == .user }.flatMap(\.attachments).suffix(8))
    }

    private static func invoke(prompt: String, systemPrompt: String, model: String, repository: URL, cancellation: JobCancellation, skill: AgentSkill? = nil, workingDirectory: URL? = nil, approveTool: (@Sendable (SkillToolApproval) async -> Bool)? = nil, images: [ChatImageAttachment] = []) throws -> String {
        try cancellation.check()
        let node = try RuntimeTools.find("node")
        let cli = repository.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
        guard FileManager.default.fileExists(atPath: cli.path) else { throw RuntimeToolFailure.missing("モデル実行コンポーネント") }
        let process = Process()
        process.executableURL = node
        var arguments = [cli.path, "--print", "--mode", skill == nil ? "text" : "json", "--no-session",
                         "--no-extensions", "--no-skills", "--no-context-files",
                         "--model", model, "--system-prompt", systemPrompt]
        if let skill {
            guard approveTool != nil else { throw PiChatFailure.approvalUnavailable }
            let gate = repository.appendingPathComponent("scripts/skill-tool-gate.mjs")
            guard FileManager.default.fileExists(atPath: gate.path) else { throw PiChatFailure.approvalUnavailable }
            arguments += ["--skill", skill.fileURL.path, "--extension", gate.path,
                          "--tools", "read,grep,find,ls,bash,edit,write"]
        } else {
            arguments.append("--no-tools")
        }
        for image in images {
            guard FileManager.default.fileExists(atPath: image.fileURL.path) else { throw ChatImageAttachmentError.missing(image.name) }
            arguments.append("@" + image.fileURL.path)
        }
        process.arguments = arguments
        if let workingDirectory, skill != nil {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            process.currentDirectoryURL = workingDirectory
        } else {
            process.currentDirectoryURL = repository
        }
        var environment = RuntimeTools.environment(prepending: node.deletingLastPathComponent())
        let approvalDirectory: URL?
        if let skill {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-workspace-approval-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            environment["AGENT_WORKSPACE_APPROVAL_DIR"] = directory.path
            environment["AGENT_WORKSPACE_SKILL_DIR"] = skill.fileURL.deletingLastPathComponent().path
            approvalDirectory = directory
        } else {
            approvalDirectory = nil
        }
        defer { if let approvalDirectory { try? FileManager.default.removeItem(at: approvalDirectory) } }
        process.environment = environment
        let approvalTask: Task<Void, Never>? = if let approvalDirectory, let approveTool {
            Task.detached(priority: .userInitiated) {
                await monitorApprovals(in: approvalDirectory, approveTool: approveTool)
            }
        } else { nil }
        defer { approvalTask?.cancel() }
        let input = Pipe()
        let output = Pipe()
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("agent-workspace-pi-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let errorOutput = try FileHandle(forWritingTo: errorURL)
        defer { try? errorOutput.close() }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput
        try cancellation.register(process)
        defer { cancellation.unregister(process) }
        try process.run()
        try cancellation.didStart(process)
        input.fileHandleForWriting.write(Data((prompt + (images.isEmpty ? "" : "\n")).utf8))
        input.fileHandleForWriting.closeFile()
        let response = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try cancellation.check()
        let rawText = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = (try? String(contentsOf: errorURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let detail = skill == nil ? String(rawText.prefix(1200)) : skillResponse(from: rawText)
            throw PiChatFailure.commandFailed(process.terminationStatus, [errorText, detail].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let text = skill == nil ? rawText : skillResponse(from: rawText)
        guard !text.isEmpty else { throw PiChatFailure.emptyResponse }
        return text
    }

    private static func monitorApprovals(in directory: URL, approveTool: @escaping @Sendable (SkillToolApproval) async -> Bool) async {
        var handled = Set<String>()
        let manager = FileManager.default
        while !Task.isCancelled {
            let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("request-") && file.pathExtension == "json" {
                guard handled.insert(file.lastPathComponent).inserted,
                      let data = try? Data(contentsOf: file),
                      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = request["id"] as? String,
                      let toolName = request["toolName"] as? String else { continue }
                let argumentsData = (try? JSONSerialization.data(withJSONObject: request["arguments"] ?? [:], options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
                let approval = SkillToolApproval(id: id, toolName: toolName, arguments: String(decoding: argumentsData, as: UTF8.self))
                let allowed = await approveTool(approval)
                let response = try? JSONSerialization.data(withJSONObject: ["approved": allowed])
                if let response {
                    let responseURL = directory.appendingPathComponent("response-\(id).json")
                    try? response.write(to: responseURL, options: .atomic)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func skillResponse(from stream: String) -> String {
        var answer = ""
        var operations: [String] = []
        var operationIndexes: [String: Int] = [:]
        for line in stream.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            if type == "message_end",
               let message = event["message"] as? [String: Any],
               message["role"] as? String == "assistant",
               let content = message["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                if !text.isEmpty { answer = text }
            } else if type == "tool_execution_start",
                      let name = event["toolName"] as? String {
                let arguments = event["args"] as? [String: Any] ?? [:]
                let detail = (arguments["command"] as? String) ?? (arguments["path"] as? String) ?? (arguments["pattern"] as? String) ?? ""
                let summary = detail.isEmpty ? name : "\(name): \(String(detail.prefix(500)))\(detail.count > 500 ? "…（省略）" : "")"
                if let id = event["toolCallId"] as? String { operationIndexes[id] = operations.count }
                operations.append(summary)
            } else if type == "tool_execution_end",
                      event["isError"] as? Bool == true,
                      let id = event["toolCallId"] as? String,
                      let index = operationIndexes[id], operations.indices.contains(index) {
                operations[index] += "（失敗）"
            }
        }
        if !operations.isEmpty {
            answer += "\n\n操作概要:\n" + operations.map { "• \($0)" }.joined(separator: "\n")
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
