import AppKit
import Combine
import Foundation

struct WorkspaceSnapshot: Codable, Sendable {
    let id: UUID
    let name: String
    let isArchived: Bool
    let messages: [ChatMessage]
    let pendingImages: [ChatImageAttachment]
    let modelID: String
    let chatInput: String
    let retryHistory: [ChatMessage]
    let retryDraft: String
    let retryModelID: String
    let retrySkillPath: String?
    let retryRevision: UInt64
    let lastPiAction: PiActionKind?
    let jsonText: String
    let sourceName: String
    let outputDirectory: URL
    let artifactURL: URL?
    let artifactSourceJSON: String?
    let artifactSourceRevision: UInt64?
    let piJobState: WorkspaceJobState
    let buildJobState: WorkspaceJobState
    let hasBuildFailure: Bool
    let status: String
    let transcript: String
    let revisionText: String
    let pendingDraft: String?
    let specRevision: UInt64
    let lastModified: Date

    init(id: UUID, name: String, isArchived: Bool, messages: [ChatMessage], pendingImages: [ChatImageAttachment], modelID: String, chatInput: String, retryHistory: [ChatMessage], retryDraft: String, retryModelID: String, retrySkillPath: String?, retryRevision: UInt64, lastPiAction: PiActionKind?, jsonText: String, sourceName: String, outputDirectory: URL, artifactURL: URL?, artifactSourceJSON: String?, artifactSourceRevision: UInt64?, piJobState: WorkspaceJobState, buildJobState: WorkspaceJobState, hasBuildFailure: Bool, status: String, transcript: String, revisionText: String, pendingDraft: String?, specRevision: UInt64, lastModified: Date) {
        self.id = id; self.name = name; self.isArchived = isArchived; self.messages = messages; self.pendingImages = pendingImages; self.modelID = modelID; self.chatInput = chatInput; self.retryHistory = retryHistory; self.retryDraft = retryDraft; self.retryModelID = retryModelID; self.retrySkillPath = retrySkillPath; self.retryRevision = retryRevision; self.lastPiAction = lastPiAction; self.jsonText = jsonText; self.sourceName = sourceName; self.outputDirectory = outputDirectory; self.artifactURL = artifactURL; self.artifactSourceJSON = artifactSourceJSON; self.artifactSourceRevision = artifactSourceRevision; self.piJobState = piJobState; self.buildJobState = buildJobState; self.hasBuildFailure = hasBuildFailure; self.status = status; self.transcript = transcript; self.revisionText = revisionText; self.pendingDraft = pendingDraft; self.specRevision = specRevision; self.lastModified = lastModified
    }

    private enum CodingKeys: String, CodingKey { case id, name, isArchived, messages, pendingImages, modelID, chatInput, retryHistory, retryDraft, retryModelID, retrySkillPath, retryRevision, lastPiAction, jsonText, sourceName, outputDirectory, artifactURL, artifactSourceJSON, artifactSourceRevision, piJobState, buildJobState, hasBuildFailure, status, transcript, revisionText, pendingDraft, specRevision, lastModified }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "ワイヤーフレーム"
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        pendingImages = try c.decodeIfPresent([ChatImageAttachment].self, forKey: .pendingImages) ?? []
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        chatInput = try c.decodeIfPresent(String.self, forKey: .chatInput) ?? ""
        retryHistory = try c.decodeIfPresent([ChatMessage].self, forKey: .retryHistory) ?? []
        retryDraft = try c.decodeIfPresent(String.self, forKey: .retryDraft) ?? ""
        retryModelID = try c.decodeIfPresent(String.self, forKey: .retryModelID) ?? ""
        retrySkillPath = try c.decodeIfPresent(String.self, forKey: .retrySkillPath)
        retryRevision = try c.decodeIfPresent(UInt64.self, forKey: .retryRevision) ?? 0
        lastPiAction = try c.decodeIfPresent(PiActionKind.self, forKey: .lastPiAction)
        jsonText = try c.decodeIfPresent(String.self, forKey: .jsonText) ?? ""
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? "workspace.json"
        outputDirectory = try c.decodeIfPresent(URL.self, forKey: .outputDirectory) ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist")
        artifactURL = try c.decodeIfPresent(URL.self, forKey: .artifactURL)
        artifactSourceJSON = try c.decodeIfPresent(String.self, forKey: .artifactSourceJSON)
        artifactSourceRevision = try c.decodeIfPresent(UInt64.self, forKey: .artifactSourceRevision)
        piJobState = try c.decodeIfPresent(WorkspaceJobState.self, forKey: .piJobState) ?? .idle
        buildJobState = try c.decodeIfPresent(WorkspaceJobState.self, forKey: .buildJobState) ?? .idle
        hasBuildFailure = try c.decodeIfPresent(Bool.self, forKey: .hasBuildFailure) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "相談内容を入力してください"
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        revisionText = try c.decodeIfPresent(String.self, forKey: .revisionText) ?? ""
        pendingDraft = try c.decodeIfPresent(String.self, forKey: .pendingDraft)
        specRevision = try c.decodeIfPresent(UInt64.self, forKey: .specRevision) ?? 0
        lastModified = try c.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
    }
}

struct WorkspaceStoreSnapshot: Codable, Sendable {
    let projects: [WorkspaceSnapshot]
    let selectedID: UUID?
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var projects: [WorkspaceModel] = []
    @Published private(set) var selectedID: UUID?
    @Published var errorMessage: String?

    var selectedProject: WorkspaceModel? { projects.first(where: { $0.id == selectedID && !$0.isArchived }) }
    var activeProjects: [WorkspaceModel] { projects.filter { !$0.isArchived } }
    var archivedProjects: [WorkspaceModel] { projects.filter { $0.isArchived } }

    private var observers: [UUID: AnyCancellable] = [:]
    private var saveTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?
    private let persistenceURL: URL
    private var recoveryBlocked = false
    private var availableModelIDs: Set<String> = []
    private var imageModelIDs: Set<String> = []

    init() {
        persistenceURL = Self.defaultPersistenceURL()
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        load()
        if projects.isEmpty { newProject() }
    }

    func newProject() {
        _ = createProject(name: nextDefaultName())
    }

    private func nextDefaultName() -> String {
        var number = 1
        while projects.contains(where: { $0.name == "新しい案 \(number)" }) { number += 1 }
        return "新しい案 \(number)"
    }

    @discardableResult
    func newProject(name: String) -> WorkspaceModel {
        createProject(name: name)
    }

    @discardableResult
    func createProject(name: String = "新しいワイヤーフレーム") -> WorkspaceModel {
        let project = WorkspaceModel()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.name = trimmedName.isEmpty ? nextDefaultName() : trimmedName
        project.setAvailableModels(availableModelIDs, imageIDs: imageModelIDs)
        projects.append(project)
        observe(project)
        selectedID = project.id
        scheduleSave()
        return project
    }

    @discardableResult
    func importProject() -> WorkspaceModel? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return importProject(from: url)
    }

    @discardableResult
    func importProject(from url: URL) -> WorkspaceModel? {
        do {
            let json = try String(contentsOf: url, encoding: .utf8)
            let project = WorkspaceModel()
            project.importInput(from: url)
            project.setAvailableModels(availableModelIDs, imageIDs: imageModelIDs)
            if project.jsonText.isEmpty { project.jsonText = json }
            projects.append(project)
            observe(project)
            selectedID = project.id
            errorMessage = nil
            scheduleSave()
            return project
        } catch {
            errorMessage = "仕様を読み込めませんでした: \(error.localizedDescription)"
            return nil
        }
    }

    func select(_ id: UUID) {
        guard projects.contains(where: { $0.id == id && !$0.isArchived }) else { return }
        selectedID = id
        scheduleSave()
    }

    func renameProject(_ id: UUID, to name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let project = projects.first(where: { $0.id == id }) else { return false }
        project.rename(to: trimmedName)
        scheduleSave()
        return true
    }

    func archiveProject(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id && !$0.isArchived }) else { return }
        project.archive()
        if selectedID == id { selectedID = activeProjects.first?.id }
        scheduleSave()
    }

    func restoreProject(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id && $0.isArchived }) else { return }
        project.restore()
        selectedID = id
        scheduleSave()
    }

    func clearError() { errorMessage = nil }

    func setAvailableModels(_ ids: Set<String>, imageIDs: Set<String> = []) {
        availableModelIDs = ids
        imageModelIDs = imageIDs
        projects.forEach { $0.setAvailableModels(ids, imageIDs: imageIDs) }
    }

    func suspendProjects(using providerID: String) {
        projects.forEach { $0.suspendForLogout(providerID: providerID) }
        setAvailableModels(availableModelIDs.filter { !$0.hasPrefix("\(providerID)/") }, imageIDs: imageModelIDs.filter { !$0.hasPrefix("\(providerID)/") })
    }

    private func observe(_ project: WorkspaceModel) {
        observers[project.id] = project.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
                self?.scheduleSave()
            }
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        guard let data = try? Data(contentsOf: persistenceURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawProjects = root["projects"] as? [Any] else {
            let backup = persistenceURL.deletingPathExtension().appendingPathExtension("corrupt-\(UUID().uuidString).json")
            do {
                try FileManager.default.moveItem(at: persistenceURL, to: backup)
                errorMessage = "保存済みワークスペースを読み込めませんでした。元のファイルを退避し、新しい案件として開始します"
            } catch {
                recoveryBlocked = true
                errorMessage = "保存済みワークスペースを読み込めず、退避にも失敗しました。元のファイルを保護するため自動保存を停止しました"
            }
            return
        }

        let snapshots = rawProjects.compactMap { raw -> WorkspaceSnapshot? in
            guard JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
            return try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        }
        let droppedCount = rawProjects.count - snapshots.count
        if droppedCount > 0 {
            let backup = persistenceURL.deletingPathExtension().appendingPathExtension("partial-\(UUID().uuidString).json")
            do {
                try FileManager.default.copyItem(at: persistenceURL, to: backup)
                errorMessage = "保存済み案件のうち、読み込めない \(droppedCount) 件をスキップしました。元の保存ファイルは退避しています"
            } catch {
                recoveryBlocked = true
                errorMessage = "保存済み案件の一部を読み込めず、退避にも失敗しました。元のファイルを保護するため自動保存を停止しました"
            }
        }
        projects = snapshots.map(WorkspaceModel.init(snapshot:))
        projects.forEach(observe)
        let restoredID = (root["selectedID"] as? String).flatMap(UUID.init(uuidString:))
        selectedID = restoredID.flatMap { id in activeProjects.contains(where: { $0.id == id }) ? id : nil } ?? activeProjects.first?.id
        if droppedCount > 0 && !recoveryBlocked { scheduleSave() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard !recoveryBlocked else { return }
        let snapshot = WorkspaceStoreSnapshot(projects: projects.map { $0.snapshot() }, selectedID: selectedID)
        do {
            let directory = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            errorMessage = "ワークスペースを保存できませんでした: \(error.localizedDescription)"
        }
    }

    private static func defaultPersistenceURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Agent Workspace", isDirectory: true).appendingPathComponent("workspace.json")
    }
}
