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

    static func reply(to messages: [ChatMessage], currentDraft: String?, model: String, repository: URL, cancellation: JobCancellation, skill: AgentSkill? = nil, skillArguments: String = "", workingDirectory: URL? = nil, approveTool: (@Sendable (SkillToolApproval) async -> Bool)? = nil) async throws -> String {
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
        if let skill {
            return try await invokeSkill(prompt: prompt, systemPrompt: systemPrompt, model: model, repository: repository, cancellation: cancellation, skill: skill, workingDirectory: workingDirectory, approveTool: approveTool, images: contextImages(messages))
        }
        return try await invoke(prompt: prompt, systemPrompt: systemPrompt, model: model, repository: repository, cancellation: cancellation, images: contextImages(messages))
    }

    static func proposeDraft(from messages: [ChatMessage], currentDraft: String?, model: String, repository: URL, cancellation: JobCancellation) async throws -> String {
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
        let raw = try await invoke(
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

    private static func invoke(prompt: String, systemPrompt: String, model: String, repository: URL, cancellation: JobCancellation, images: [ChatImageAttachment] = []) async throws -> String {
        try cancellation.check()
        let node = try RuntimeTools.find("node")
        let cli = try commandLineInterface(in: repository)
        let process = Process()
        process.executableURL = node
        var arguments = [cli.path, "--print", "--mode", "text", "--no-session",
                         "--no-extensions", "--no-skills", "--no-context-files",
                         "--model", model, "--system-prompt", systemPrompt, "--no-tools"]
        for image in images {
            guard FileManager.default.fileExists(atPath: image.fileURL.path) else { throw ChatImageAttachmentError.missing(image.name) }
            arguments.append("@" + image.fileURL.path)
        }
        process.arguments = arguments
        process.currentDirectoryURL = repository
        process.environment = RuntimeTools.environment(prepending: node.deletingLastPathComponent())
        let input = Pipe()
        let output = Pipe()
        let errorLog = try ErrorLog()
        defer { errorLog.discard() }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorLog.handle
        let outcome = try await ProcessRunner.run(
            process,
            output: output,
            input: (pipe: input, data: Data((prompt + (images.isEmpty ? "" : "\n")).utf8)),
            cancellation: cancellation
        )
        let rawText = String(decoding: outcome.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard outcome.terminationReason == .exit, outcome.terminationStatus == 0 else {
            throw PiChatFailure.commandFailed(outcome.terminationStatus, [errorLog.text(), String(rawText.prefix(1200))].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        guard !rawText.isEmpty else { throw PiChatFailure.emptyResponse }
        return rawText
    }

    /// スキル実行はツール承認を伴うため `--mode rpc` を使う。
    ///
    /// 承認の往復は親プロセスのstdin/stdoutパイプ（`extension_ui_request` / `extension_ui_response`）
    /// だけで完結する。同一ユーザーで動く子プロセスからはこのパイプに触れられないため、
    /// 以前のファイルシステム経由の承認プロトコルにあった偽装経路が原理的に塞がれる。
    private static func invokeSkill(prompt: String, systemPrompt: String, model: String, repository: URL, cancellation: JobCancellation, skill: AgentSkill, workingDirectory: URL?, approveTool: (@Sendable (SkillToolApproval) async -> Bool)?, images: [ChatImageAttachment]) async throws -> String {
        try cancellation.check()
        guard let approveTool else { throw PiChatFailure.approvalUnavailable }
        let node = try RuntimeTools.find("node")
        let cli = try commandLineInterface(in: repository)
        let gate = repository.appendingPathComponent("scripts/skill-tool-gate.mjs")
        guard FileManager.default.fileExists(atPath: gate.path) else { throw PiChatFailure.approvalUnavailable }
        var imagePayload: [[String: String]] = []
        for image in images {
            guard let data = try? Data(contentsOf: image.fileURL) else { throw ChatImageAttachmentError.missing(image.name) }
            imagePayload.append(["type": "image", "data": data.base64EncodedString(), "mimeType": image.mimeType])
        }
        let process = Process()
        process.executableURL = node
        process.arguments = [cli.path, "--mode", "rpc", "--no-session",
                             "--no-extensions", "--no-skills", "--no-context-files",
                             "--model", model, "--system-prompt", systemPrompt,
                             "--skill", skill.fileURL.path, "--extension", gate.path,
                             "--tools", "read,grep,find,ls,bash,edit,write"]
        if let workingDirectory {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            process.currentDirectoryURL = workingDirectory
        } else {
            process.currentDirectoryURL = repository
        }
        var environment = RuntimeTools.environment(prepending: node.deletingLastPathComponent())
        environment["AGENT_WORKSPACE_SKILL_DIR"] = skill.fileURL.deletingLastPathComponent().path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        let errorLog = try ErrorLog()
        defer { errorLog.discard() }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorLog.handle
        let session = RPCSession(process: process, input: input, output: output)
        defer { cancellation.unregister(process) }
        try session.start(cancellation: cancellation)
        var command: [String: Any] = ["type": "prompt", "message": prompt]
        if !imagePayload.isEmpty { command["images"] = imagePayload }
        session.send(command)

        var stream = ""
        var settled = false
        await withTaskCancellationHandler {
            for await line in session.lines {
                stream += line + "\n"
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = event["type"] as? String else { continue }
                if type == "extension_ui_request" {
                    await respond(to: event, session: session, approveTool: approveTool)
                } else if type == "agent_settled" {
                    settled = true
                    break
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        // 応答が確定しても pi は対話セッションとして待機し続ける。abort で実行中の処理を止め、
        // 標準入力を閉じてEOFを渡すと終了コード0で正常終了する。
        session.send(["type": "abort"])
        session.closeInput()
        let watchdog = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            session.terminate()
        }
        let exit = await session.waitForExit()
        watchdog.cancel()
        try cancellation.check()
        let text = skillResponse(from: stream)
        guard settled else {
            throw PiChatFailure.commandFailed(exit.status, [errorLog.text(), text].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        guard !text.isEmpty else { throw PiChatFailure.emptyResponse }
        return text
    }

    /// 拡張機能のUI要求に答える。`confirm` は承認ダイアログへ、その他のダイアログは
    /// 応答しないとエージェントが止まるため取り消しとして返す。通知系は応答不要。
    private static func respond(to event: [String: Any], session: RPCSession, approveTool: @Sendable (SkillToolApproval) async -> Bool) async {
        guard let id = event["id"] as? String, let method = event["method"] as? String else { return }
        switch method {
        case "confirm":
            let toolName = event["title"] as? String ?? "操作"
            let arguments = event["message"] as? String ?? ""
            let allowed = await approveTool(SkillToolApproval(id: id, toolName: toolName, arguments: arguments))
            session.send(["type": "extension_ui_response", "id": id, "confirmed": allowed])
        case "select", "input", "editor":
            session.send(["type": "extension_ui_response", "id": id, "cancelled": true])
        default:
            break
        }
    }

    private static func commandLineInterface(in repository: URL) throws -> URL {
        let cli = repository.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/dist/cli.js")
        guard FileManager.default.fileExists(atPath: cli.path) else { throw RuntimeToolFailure.missing("モデル実行コンポーネント") }
        return cli
    }

    /// 子プロセスの標準エラー出力を一時ファイルへ退避するための小さな入れ物。
    private final class ErrorLog {
        let url: URL
        let handle: FileHandle

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-workspace-pi-\(UUID().uuidString).log")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: url)
        }

        func text() -> String {
            (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        func discard() {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
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
