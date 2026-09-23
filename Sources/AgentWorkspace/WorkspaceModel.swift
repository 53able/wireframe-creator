import AppKit
import Combine
import Foundation

enum WorkspaceJobState: String, Codable, Sendable {
    case idle
    case running
    case succeeded
    case failed
    case interrupted
}

enum PiActionKind: String, Codable, Sendable {
    case chat
    case draft
    case revision
}

@MainActor
final class WorkspaceModel: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    @Published private(set) var isArchived = false
    @Published var messages: [ChatMessage]
    @Published var chatInput = ""
    @Published private(set) var pendingImages: [ChatImageAttachment] = []
    @Published private(set) var isImportingImages = false
    @Published var attachmentError: String?
    @Published var modelID = ""
    @Published private(set) var availableModelIDs: Set<String> = []
    @Published private(set) var imageModelIDs: Set<String> = []
    @Published private(set) var piJobState: WorkspaceJobState = .idle
    @Published private(set) var lastPiAction: PiActionKind?
    @Published var jsonText = "" { didSet { if oldValue != jsonText { draftRevision &+= 1; lastModified = Date(); scheduleOperationAnalysis() } } }
    @Published private(set) var operationReport: OperationCapabilityReport?
    @Published private(set) var artifactOperationReport: OperationCapabilityReport?
    @Published private(set) var operationAnalysisError: String?
    @Published var sourceName = "workspace.json"
    @Published var outputDirectory: URL
    @Published var artifactURL: URL?
    @Published var artifactSourceJSON: String?
    @Published private(set) var artifactSourceRevision: UInt64?
    @Published private(set) var buildJobState: WorkspaceJobState = .idle
    @Published var hasBuildFailure = false
    @Published var status = "相談内容を入力してください"
    @Published var transcript = ""
    @Published var revisionText = ""
    @Published private(set) var pendingDraft: String?
    @Published private(set) var pendingToolApproval: SkillToolApproval?
    @Published private(set) var lastModified = Date()

    let repository: URL
    private var draftRevision: UInt64 = 0
    private var piJobToken: UUID?
    private var buildJobToken: UUID?
    private var piCancellation: JobCancellation?
    private var buildCancellation: JobCancellation?
    private var activePiProviderID: String?
    private var activeBuildProviderID: String?
    private var retryHistory: [ChatMessage] = []
    private var retryDraft = ""
    private var retryModelID = ""
    private var retrySkillPath: String?
    private var retryRevision: UInt64 = 0
    private var toolApprovalContinuation: CheckedContinuation<Bool, Never>?
    private var imageImportsInFlight = 0
    private var operationAnalysisTask: Task<Void, Never>?
    private var operationAnalysisEnabled = false

    var isResponding: Bool { piJobState == .running }
    var isBuilding: Bool { buildJobState == .running }
    var specRevision: UInt64 { draftRevision }
    var canRetryPi: Bool {
        let model = retryModelID.isEmpty ? modelID : retryModelID
        return !isArchived && lastPiAction != nil && !retryHistory.isEmpty && !isResponding && availableModelIDs.contains(model)
    }
    var canUseSelectedModel: Bool { !isArchived && availableModelIDs.contains(modelID) }
    var retrySkillName: String? {
        guard lastPiAction == .chat, let message = retryHistory.last?.text, message.hasPrefix("/") else { return nil }
        return String(message.dropFirst().prefix(while: { !$0.isWhitespace }))
    }

    func resolveToolApproval(_ approved: Bool) {
        pendingToolApproval = nil
        toolApprovalContinuation?.resume(returning: approved)
        toolApprovalContinuation = nil
    }

    private func awaitToolApproval(_ request: SkillToolApproval) async -> Bool {
        guard canUseSelectedModel, isResponding else { return false }
        return await withCheckedContinuation { continuation in
            pendingToolApproval = request
            toolApprovalContinuation = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                if self.pendingToolApproval?.id == request.id { self.resolveToolApproval(false) }
            }
        }
    }

    func setAvailableModels(_ ids: Set<String>, imageIDs: Set<String> = []) {
        availableModelIDs = ids
        imageModelIDs = imageIDs
    }

    private func supportsImages(for history: [ChatMessage], model: String) -> Bool {
        !history.contains(where: { !$0.attachments.isEmpty }) || imageModelIDs.contains(model)
    }

    func rename(to newName: String) {
        guard name != newName else { return }
        name = newName
        touch()
    }

    func archive() {
        guard !isArchived else { return }
        resolveToolApproval(false)
        let hadRunningJob = isResponding || isBuilding
        if isResponding {
            piCancellation?.cancel()
            piJobToken = UUID()
            piJobState = .interrupted
        }
        if isBuilding {
            buildCancellation?.cancel()
            buildJobToken = UUID()
            buildJobState = .interrupted
            hasBuildFailure = true
        }
        isArchived = true
        if hadRunningJob { status = "アーカイブしたため処理を中断しました。復帰後に再試行できます" }
        touch()
    }

    func restore() {
        guard isArchived else { return }
        isArchived = false
        if piJobState == .interrupted || buildJobState == .interrupted {
            status = "案件を復帰しました。中断された処理は必要に応じて再実行してください"
        }
        touch()
    }

    func suspendForLogout(providerID: String) {
        let selectedProvider = modelID.hasPrefix("\(providerID)/")
        let piAffected = isResponding && activePiProviderID == providerID
        let buildAffected = isBuilding && activeBuildProviderID == providerID
        guard selectedProvider || piAffected || buildAffected else { return }
        resolveToolApproval(false)
        if piAffected {
            piCancellation?.cancel()
            piJobToken = UUID()
            piJobState = .interrupted
        }
        if buildAffected {
            buildCancellation?.cancel()
            buildJobToken = UUID()
            buildJobState = .interrupted
            hasBuildFailure = true
        }
        status = "モデルからログアウトしたため作業を一時停止しました。再ログイン後に再試行できます"
        touch()
    }

    init() {
        let defaults = WorkspaceDefaults()
        id = UUID()
        name = "新しいワイヤーフレーム"
        messages = [ChatMessage(role: .assistant, text: "何を検証するワイヤーフレームを作りますか？対象ユーザーと主な操作を教えてください。")]
        repository = defaults.repository
        outputDirectory = defaults.outputDirectory
        operationAnalysisEnabled = true
    }

    init(snapshot: WorkspaceSnapshot) {
        let defaults = WorkspaceDefaults()
        id = snapshot.id
        name = snapshot.name
        isArchived = snapshot.isArchived
        messages = snapshot.messages.isEmpty ? [ChatMessage(role: .assistant, text: "何を検証するワイヤーフレームを作りますか？対象ユーザーと主な操作を教えてください。")] : snapshot.messages
        modelID = snapshot.modelID
        jsonText = snapshot.jsonText
        sourceName = snapshot.sourceName
        repository = defaults.repository
        outputDirectory = snapshot.outputDirectory
        artifactURL = snapshot.artifactURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        artifactSourceJSON = snapshot.artifactSourceJSON
        artifactSourceRevision = snapshot.artifactSourceRevision
        hasBuildFailure = snapshot.hasBuildFailure
        status = snapshot.status
        transcript = snapshot.transcript
        revisionText = snapshot.revisionText
        pendingDraft = snapshot.pendingDraft
        chatInput = snapshot.chatInput
        pendingImages = snapshot.pendingImages
        draftRevision = snapshot.specRevision
        lastPiAction = snapshot.lastPiAction
        retryHistory = snapshot.retryHistory
        retryDraft = snapshot.retryDraft
        retryModelID = snapshot.retryModelID
        retrySkillPath = snapshot.retrySkillPath
        retryRevision = snapshot.retryRevision
        lastModified = snapshot.lastModified
        piJobState = snapshot.piJobState == .running ? .interrupted : snapshot.piJobState
        buildJobState = snapshot.buildJobState == .running ? .interrupted : snapshot.buildJobState
        if buildJobState == .interrupted { hasBuildFailure = true }
        if piJobState == .interrupted || buildJobState == .interrupted { status = "前回の処理は中断されました。必要なら再実行してください" }
        operationAnalysisEnabled = true
        scheduleOperationAnalysis()
        if let artifactJSON = artifactSourceJSON { scheduleArtifactOperationAnalysis(artifactJSON) }
    }

    func snapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(id: id, name: name, isArchived: isArchived, messages: messages, pendingImages: pendingImages, modelID: modelID, chatInput: chatInput, retryHistory: retryHistory, retryDraft: retryDraft, retryModelID: retryModelID, retrySkillPath: retrySkillPath, retryRevision: retryRevision, lastPiAction: lastPiAction, jsonText: jsonText, sourceName: sourceName, outputDirectory: outputDirectory, artifactURL: artifactURL, artifactSourceJSON: artifactSourceJSON, artifactSourceRevision: artifactSourceRevision, piJobState: piJobState, buildJobState: buildJobState, hasBuildFailure: hasBuildFailure, status: status, transcript: transcript, revisionText: revisionText, pendingDraft: pendingDraft, specRevision: draftRevision, lastModified: lastModified)
    }

    private func scheduleOperationAnalysis() {
        guard operationAnalysisEnabled else { return }
        operationAnalysisTask?.cancel()
        let json = jsonText
        let revision = draftRevision
        let root = repository
        operationReport = nil
        operationAnalysisError = nil
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        operationAnalysisTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            do {
                let report = try await Task.detached(priority: .utility) {
                    try OperationCapabilityService.analyze(json: json, repository: root)
                }.value
                guard !Task.isCancelled else { return }
                guard let self, self.draftRevision == revision, self.jsonText == json else { return }
                self.operationReport = report
                self.operationAnalysisError = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.draftRevision == revision, self.jsonText == json else { return }
                self.operationReport = nil
                self.operationAnalysisError = error.localizedDescription
            }
        }
    }

    func addImage(from url: URL) {
        let projectID = id
        importImage { try ChatImageAttachmentStore.importFile(url, projectID: projectID) }
    }

    func addImage(data: Data, name: String) {
        let projectID = id
        importImage { try ChatImageAttachmentStore.importData(data, name: name, projectID: projectID) }
    }

    private func importImage(_ operation: @escaping @Sendable () throws -> ChatImageAttachment) {
        guard !isArchived else { return }
        guard pendingImages.count + imageImportsInFlight < 8 else {
            attachmentError = ChatImageAttachmentError.tooMany.localizedDescription
            return
        }
        attachmentError = nil
        imageImportsInFlight += 1
        isImportingImages = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try operation() }
            await MainActor.run {
                self.imageImportsInFlight -= 1
                self.isImportingImages = self.imageImportsInFlight > 0
                switch result {
                case .success(let image): self.pendingImages.append(image); self.touch()
                case .failure(let error): self.attachmentError = error.localizedDescription
                }
            }
        }
    }

    func removePendingImage(_ id: UUID) {
        guard let index = pendingImages.firstIndex(where: { $0.id == id }) else { return }
        let image = pendingImages.remove(at: index)
        try? FileManager.default.removeItem(at: image.fileURL)
        attachmentError = nil
        touch()
    }

    func applyPendingDraft() { guard canUseSelectedModel, let pendingDraft else { return }; jsonText = pendingDraft; self.pendingDraft = nil; status = "仕様案を適用しました。内容を確認してください"; touch() }
    func discardPendingDraft() { pendingDraft = nil; status = "改訂案を破棄しました"; touch() }

    func openInput() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }; importInput(from: url)
    }

    func importInput(from url: URL) {
        do {
            jsonText = try String(contentsOf: url, encoding: .utf8); sourceName = url.lastPathComponent; name = url.deletingPathExtension().lastPathComponent
            artifactURL = nil; artifactSourceJSON = nil; artifactSourceRevision = nil; artifactOperationReport = nil; transcript = ""; hasBuildFailure = false; status = "\(sourceName)を読み込みました"; touch()
        } catch { status = "入力を読み込めませんでした"; transcript = error.localizedDescription; touch() }
    }

    func sendMessage(selectedSkill: AgentSkill? = nil) {
        let message = chatInput.trimmingCharacters(in: .whitespacesAndNewlines); guard (!message.isEmpty || !pendingImages.isEmpty), canUseSelectedModel, !isResponding, !isImportingImages else { return }
        guard supportsImages(for: messages + [ChatMessage(role: .user, text: message, attachments: pendingImages)], model: modelID) else {
            status = "この会話に添付画像があります。画像対応モデルを選んでください"
            return
        }
        for image in pendingImages where !FileManager.default.fileExists(atPath: image.fileURL.path) {
            attachmentError = ChatImageAttachmentError.missing(image.name).localizedDescription
            return
        }
        let command = message.hasPrefix("/") ? AgentSkillCatalog.resolve(message, among: selectedSkill.map { [$0] } ?? []) : .ordinary
        let skill: AgentSkill?
        let skillArguments: String
        switch command {
        case .ordinary:
            skill = nil; skillArguments = ""
        case .selected(let selected, let arguments):
            skill = selected; skillArguments = arguments
        case .unknown(let name):
            status = "スキル「\(name)」が見つかりません。候補を更新して選び直してください"
            return
        }
        chatInput = ""; messages.append(ChatMessage(role: .user, text: message, attachments: pendingImages)); pendingImages = []; attachmentError = nil; piJobState = .running
        let token = UUID(); piJobToken = token; let history = messages; let draft = jsonText; let model = modelID; let root = repository; let directory = outputDirectory; let capturedRevision = draftRevision; let cancellation = JobCancellation(); piCancellation = cancellation; activePiProviderID = String(model.split(separator: "/", maxSplits: 1).first ?? ""); touch()
        if let skill { status = "スキル「\(skill.name)」を実行中" }
        saveRetryContext(kind: .chat, history: history, draft: draft, model: model, revision: capturedRevision, skill: skill)
        Task.detached(priority: .userInitiated) {
            do {
                let reply = try PiChatService.reply(to: history, currentDraft: draft, model: model, repository: root, cancellation: cancellation, skill: skill, skillArguments: skillArguments, workingDirectory: directory, approveTool: { request in
                    await self.awaitToolApproval(request)
                })
                await MainActor.run {
                    guard self.piJobToken == token else { return }
                    let text = self.draftRevision == capturedRevision ? reply : "（この応答は、現在の仕様に変更される前の内容をもとにしています）\n\(reply)"
                    self.messages.append(ChatMessage(role: .assistant, text: text)); self.piJobState = .succeeded; self.status = "応答を受け取りました"; self.touch()
                }
            } catch {
                await MainActor.run { guard self.piJobToken == token else { return }; self.messages.append(ChatMessage(role: .assistant, text: "モデルに接続できませんでした。\n\(error.localizedDescription)")); self.piJobState = .failed; self.status = "モデルへの接続に失敗しました"; self.touch() }
            }
        }
    }

    func proposeDraft() {
        guard !isResponding, canUseSelectedModel, pendingDraft == nil, messages.contains(where: { $0.role == .user }) else { return }
        guard supportsImages(for: messages, model: modelID) else { status = "画像対応モデルを選んでください"; return }
        piJobState = .running; status = "画面仕様を作成中"; hasBuildFailure = false
        let token = UUID(); piJobToken = token; let history = messages; let draft = jsonText; let model = modelID; let root = repository; let cancellation = JobCancellation(); piCancellation = cancellation; activePiProviderID = String(model.split(separator: "/", maxSplits: 1).first ?? ""); touch()
        let capturedRevision = draftRevision
        saveRetryContext(kind: .draft, history: history, draft: draft, model: model, revision: capturedRevision)
        Task.detached(priority: .userInitiated) {
            do {
                let proposed = try PiChatService.proposeDraft(from: history, currentDraft: draft, model: model, repository: root, cancellation: cancellation)
                await MainActor.run { guard self.piJobToken == token else { return }; self.acceptProposal(proposed, capturedDraft: draft, capturedRevision: capturedRevision, message: "画面仕様案を作りました。") }
            } catch {
                await MainActor.run { guard self.piJobToken == token else { return }; self.messages.append(ChatMessage(role: .assistant, text: "仕様案を作れませんでした。\n\(error.localizedDescription)")); self.status = "仕様案の作成に失敗しました"; self.piJobState = .failed; self.touch() }
            }
        }
    }

    func reviseDraft(_ instruction: String) {
        let revision = instruction.trimmingCharacters(in: .whitespacesAndNewlines); guard !revision.isEmpty, canUseSelectedModel, !isResponding, pendingDraft == nil, !jsonText.isEmpty else { return }
        guard supportsImages(for: messages, model: modelID) else { status = "画像対応モデルを選んでください"; return }
        messages.append(ChatMessage(role: .user, text: revision)); revisionText = ""; piJobState = .running; status = "仕様案を改訂中"
        let token = UUID(); piJobToken = token; let history = messages; let draft = jsonText; let model = modelID; let root = repository; let cancellation = JobCancellation(); piCancellation = cancellation; activePiProviderID = String(model.split(separator: "/", maxSplits: 1).first ?? ""); touch()
        let capturedRevision = draftRevision
        saveRetryContext(kind: .revision, history: history, draft: draft, model: model, revision: capturedRevision)
        Task.detached(priority: .userInitiated) {
            do {
                let proposed = try PiChatService.proposeDraft(from: history, currentDraft: draft, model: model, repository: root, cancellation: cancellation)
                await MainActor.run { guard self.piJobToken == token else { return }; self.acceptProposal(proposed, capturedDraft: draft, capturedRevision: capturedRevision, message: "修正指示を反映した仕様案を作りました。") }
            } catch {
                await MainActor.run { guard self.piJobToken == token else { return }; self.messages.append(ChatMessage(role: .assistant, text: "改訂案を作れませんでした。\n\(error.localizedDescription)")); self.status = "改訂案の作成に失敗しました"; self.piJobState = .failed; self.touch() }
            }
        }
    }

    func retryPi() {
        guard canRetryPi, let action = lastPiAction else { return }
        let history = retryHistory
        let draft = retryDraft
        let model = retryModelID.isEmpty ? modelID : retryModelID
        guard availableModelIDs.contains(model) else { return }
        guard supportsImages(for: history, model: model) else { status = "画像対応モデルを選んでください"; return }
        let retrySkill = retrySkillPath.flatMap { path -> AgentSkill? in
            guard let name = retrySkillName, FileManager.default.fileExists(atPath: path) else { return nil }
            return AgentSkill(name: name.hasPrefix("skill:") ? String(name.dropFirst(6)) : name,
                              description: "", fileURL: URL(fileURLWithPath: path))
        }
        let command = action == .chat && history.last?.text.hasPrefix("/") == true
            ? AgentSkillCatalog.resolve(history.last?.text ?? "", among: retrySkill.map { [$0] } ?? []) : .ordinary
        let skill: AgentSkill?
        let skillArguments: String
        switch command {
        case .ordinary:
            skill = nil; skillArguments = ""
        case .selected(let selected, let arguments):
            skill = selected; skillArguments = arguments
        case .unknown(let name):
            status = "スキル「\(name)」が見つからないため再試行できません"
            return
        }
        let root = repository
        let directory = outputDirectory
        let capturedRevision = retryRevision
        let token = UUID()
        piJobToken = token
        let cancellation = JobCancellation()
        piCancellation = cancellation
        activePiProviderID = String(model.split(separator: "/", maxSplits: 1).first ?? "")
        piJobState = .running
        status = action == .chat ? "応答を再試行中" : "仕様案を再試行中"
        Task.detached(priority: .userInitiated) {
            do {
                let response: String
                switch action {
                case .chat:
                    response = try PiChatService.reply(to: history, currentDraft: draft, model: model, repository: root, cancellation: cancellation, skill: skill, skillArguments: skillArguments, workingDirectory: directory, approveTool: { request in
                        await self.awaitToolApproval(request)
                    })
                case .draft, .revision:
                    response = try PiChatService.proposeDraft(from: history, currentDraft: draft, model: model, repository: root, cancellation: cancellation)
                }
                await MainActor.run {
                    guard self.piJobToken == token else { return }
                    if action == .chat {
                        let text = self.draftRevision == capturedRevision ? response : "（この応答は、現在の仕様に変更される前の内容をもとにしています）\n\(response)"
                        self.messages.append(ChatMessage(role: .assistant, text: text))
                        self.piJobState = .succeeded
                        self.status = "応答を受け取りました"
                        self.touch()
                    } else {
                        let message = action == .revision ? "修正指示を反映した仕様案を作りました。" : "画面仕様案を作りました。"
                        self.acceptProposal(response, capturedDraft: draft, capturedRevision: capturedRevision, message: message)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.piJobToken == token else { return }
                    self.piJobState = .failed
                    self.status = "モデルへの接続に失敗しました"
                    self.messages.append(ChatMessage(role: .assistant, text: "モデルに接続できませんでした。\n\(error.localizedDescription)"))
                    self.touch()
                }
            }
        }
    }

    func retryInterruptedPi() {
        retryPi()
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }; outputDirectory = url; status = "保存先を変更しました"; touch()
    }

    func build() {
        guard !isBuilding, canUseSelectedModel, !jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        buildJobState = .running; hasBuildFailure = false; status = "生成と検証を実行中"; transcript = ""
        let token = UUID(); buildJobToken = token; let capturedRevision = draftRevision; let json = jsonText; let name = sourceName; let directory = outputDirectory; let root = repository; let cancellation = JobCancellation(); buildCancellation = cancellation; activeBuildProviderID = String(modelID.split(separator: "/", maxSplits: 1).first ?? ""); touch()
        Task.detached(priority: .userInitiated) {
            do {
                let result = try BuildService.build(json: json, sourceName: name, outputDirectory: directory, repository: root, cancellation: cancellation)
                await MainActor.run { guard self.buildJobToken == token else { return }; self.artifactURL = result.artifactURL; self.artifactSourceJSON = json; self.artifactSourceRevision = capturedRevision; self.artifactOperationReport = nil; self.scheduleArtifactOperationAnalysis(json); self.transcript = result.transcript; self.status = self.draftRevision == capturedRevision ? "構造チェック合格。HTMLを保存しました" : "前の仕様のHTMLを保存しました。現在の仕様を再生成できます"; self.hasBuildFailure = false; self.buildJobState = .succeeded; self.touch() }
            } catch {
                await MainActor.run { guard self.buildJobToken == token else { return }; self.transcript = error.localizedDescription; self.status = "生成または検証に失敗しました"; self.hasBuildFailure = true; self.buildJobState = .failed; self.touch() }
            }
        }
    }

    private func acceptProposal(_ proposed: String, capturedDraft: String, capturedRevision: UInt64, message: String) {
        if jsonText == capturedDraft && draftRevision == capturedRevision {
            jsonText = proposed
            pendingDraft = nil
            status = "\(message)内容を確認してください"
        } else {
            pendingDraft = proposed
            status = "\(message)編集中に届いた改訂案の確認待ち"
        }
        messages.append(ChatMessage(role: .assistant, text: message))
        piJobState = .succeeded
        touch()
    }

    private func scheduleArtifactOperationAnalysis(_ json: String) {
        let root = repository
        Task { [weak self] in
            do {
                let report = try await Task.detached(priority: .utility) {
                    try OperationCapabilityService.analyze(json: json, repository: root)
                }.value
                guard let self, self.artifactSourceJSON == json else { return }
                self.artifactOperationReport = report
            } catch {
                guard let self, self.artifactSourceJSON == json else { return }
                self.artifactOperationReport = nil
            }
        }
    }

    private func touch() { lastModified = Date() }

    private func saveRetryContext(kind: PiActionKind, history: [ChatMessage], draft: String, model: String, revision: UInt64, skill: AgentSkill? = nil) {
        lastPiAction = kind
        retryHistory = history
        retryDraft = draft
        retryModelID = model
        retrySkillPath = skill?.fileURL.path
        retryRevision = revision
    }
}

private struct WorkspaceDefaults {
    let repository: URL
    let outputDirectory: URL
    init() {
        repository = WorkspaceResources.repository
        if Bundle.main.resourceURL == repository {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
            outputDirectory = documents.appendingPathComponent("Agent Workspace", isDirectory: true)
        } else {
            outputDirectory = repository.appendingPathComponent("dist", isDirectory: true)
        }
    }
}
