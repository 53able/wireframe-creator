import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct AgentWorkspaceApp: App {
    var body: some Scene {
        Window("Agent Workspace", id: "main") {
            WorkspaceView()
        }
        .defaultSize(width: 1600, height: 900)
    }
}

private struct WorkspaceView: View {
    @StateObject private var store = WorkspaceStore()
    @StateObject private var connections = ProviderConnectionStore()
    @State private var loginInput = ""
    @State private var loginSelection = ""
    @State private var isNamingNewProject = false
    @State private var newProjectName = ""
    @State private var editingProjectID: UUID?
    @State private var editingName = ""
    @State private var nameError: String?
    @State private var archivedExpanded = false
    @State private var availableSkills: [AgentSkill] = []
    @State private var skillCatalogError: String?
    @FocusState private var projectNameFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            projectSidebar
                .frame(width: 250)
            Divider()
            if let project = store.selectedProject {
                ProjectWorkspaceView(model: project, connections: connections, availableSkills: availableSkills, skillCatalogError: skillCatalogError, refreshSkills: refreshSkills)
                    .id(project.id)
            } else {
                ContentUnavailableView {
                    Label("作業中の案件がありません", systemImage: "square.stack")
                } description: {
                    Text("新しい案を作るか、アーカイブから案件を復帰してください")
                } actions: {
                    Button("新しい案を作る") { store.newProject() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            syncAvailableModels()
            refreshSkills()
        }
        .onChange(of: connections.providers) { _, _ in syncAvailableModels() }
    }

    private func syncAvailableModels() {
        store.setAvailableModels(
            Set(connections.availableModels.map { "\($0.provider.id)/\($0.model.id)" }),
            imageIDs: Set(connections.availableModels.filter { $0.model.supportsImages == true }.map { "\($0.provider.id)/\($0.model.id)" })
        )
    }

    private func refreshSkills() {
        Task {
            do {
                availableSkills = try await Task.detached { try AgentSkillCatalog.discover() }.value
                skillCatalogError = nil
            } catch {
                skillCatalogError = error.localizedDescription
            }
        }
    }

    private func logout(_ providerID: String) {
        store.suspendProjects(using: providerID)
        connections.disconnect(providerID)
        syncAvailableModels()
    }

    private var projectSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("案件").font(.title2.bold())
                Spacer()
                Button(action: store.newProject) {
                    Image(systemName: "plus")
                }
                .help("既定名で新規案件")
                .accessibilityLabel("既定名で新規案件")
                Button {
                    editingProjectID = nil
                    newProjectName = ""
                    nameError = nil
                    isNamingNewProject = true
                    projectNameFocused = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("名前を付けて新規案件")
                .accessibilityLabel("名前を付けて新規案件")
            }
            if isNamingNewProject {
                HStack(spacing: 4) {
                    TextField("案件名", text: $newProjectName)
                        .focused($projectNameFocused)
                        .onSubmit(createNamedProject)
                    Button("作成", action: createNamedProject)
                        .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消") { isNamingNewProject = false; nameError = nil }
                }
                .controlSize(.small)
            }
            if let nameError {
                Text(nameError).font(.caption).foregroundStyle(.red)
            }
            Button("仕様ファイルを読み込む") { _ = store.importProject() }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.activeProjects) { project in
                        projectRow(project)
                    }
                    if store.activeProjects.isEmpty {
                        Text("作業中の案件はありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                    }
                    if !store.archivedProjects.isEmpty {
                        DisclosureGroup(isExpanded: $archivedExpanded) {
                            ForEach(store.archivedProjects) { project in
                                projectRow(project)
                            }
                        } label: {
                            Label("アーカイブ (\(store.archivedProjects.count))", systemImage: "archivebox")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.top, 10)
                    }
                }
            }
            Divider()
            connectionPanel
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func projectRow(_ project: WorkspaceModel) -> some View {
        if editingProjectID == project.id {
            HStack(spacing: 4) {
                TextField("案件名", text: $editingName)
                    .focused($projectNameFocused)
                    .onSubmit(saveProjectName)
                Button("保存", action: saveProjectName)
                    .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消") { editingProjectID = nil; nameError = nil }
            }
            .controlSize(.small)
            .padding(7)
        } else {
            HStack(spacing: 4) {
                Button {
                    if project.isArchived { store.restoreProject(project.id) }
                    else { store.select(project.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name)
                            .font(.body.weight(store.selectedID == project.id ? .semibold : .regular))
                            .lineLimit(2)
                        if project.isArchived {
                            Text("復帰する").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(project.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if project.pendingToolApproval != nil {
                                Label("操作の許可待ち", systemImage: "hand.raised").font(.caption2)
                            } else if project.isResponding || project.isBuilding {
                                Label("処理中", systemImage: "circle.dotted").font(.caption2)
                            } else if project.piJobState == .failed || project.buildJobState == .failed || project.piJobState == .interrupted || project.buildJobState == .interrupted {
                                Label("要確認", systemImage: "exclamationmark.circle").font(.caption2)
                            } else if project.pendingDraft != nil {
                                Label("改訂案あり", systemImage: "doc.badge.clock").font(.caption2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(store.selectedID == project.id ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(project.isArchived ? "案件 \(project.name) を復帰" : "案件 \(project.name)、\(project.status)")
                Menu {
                    Button("名前を変更") {
                        isNamingNewProject = false
                        editingProjectID = project.id
                        editingName = project.name
                        nameError = nil
                        projectNameFocused = true
                    }
                    if project.isArchived {
                        Button("復帰") { store.restoreProject(project.id) }
                    } else {
                        Button("アーカイブ") {
                            store.archiveProject(project.id)
                            archivedExpanded = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 20, height: 28)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("\(project.name) の操作")
            }
        }
    }

    private func createNamedProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { nameError = "案件名を入力してください"; return }
        store.newProject(name: name)
        isNamingNewProject = false
        newProjectName = ""
        nameError = nil
    }

    private func saveProjectName() {
        guard let id = editingProjectID else { return }
        guard store.renameProject(id, to: editingName) else { nameError = "案件名を入力してください"; return }
        editingProjectID = nil
        nameError = nil
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("モデルプロバイダー").font(.headline)
                Spacer()
                Button(action: connections.refresh) { Image(systemName: "arrow.clockwise") }
                    .disabled(connections.isLoading)
                    .help("接続状態とモデルを更新")
            }
            if connections.providers.isEmpty && connections.isLoading {
                ProgressView("モデルを読み込み中")
            }
            ForEach(connections.providers) { provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider.name).font(.caption.weight(.semibold))
                        Spacer()
                        Text(provider.connected ? "接続済み" : "未接続")
                            .font(.caption2)
                            .foregroundStyle(provider.connected ? Color.green : Color.secondary)
                    }
                    HStack {
                        Button(provider.connected ? "再接続" : "接続") {
                            connections.connect(provider.id)
                        }
                        .disabled(connections.isLoading)
                        .controlSize(.small)
                        if provider.connected {
                            Button("ログアウト") { logout(provider.id) }
                                .disabled(connections.isLoading)
                                .controlSize(.small)
                        }
                    }
                }
            }
            if let active = connections.activeProviderID {
                Text("\(connections.providers.first(where: { $0.id == active })?.name ?? active) を\(connections.activeCommand == "logout" ? "ログアウト中" : "接続中")")
                    .font(.caption.weight(.semibold))
                if let progress = connections.progress {
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
                if let code = connections.deviceCode {
                    Text("確認コード: \(code)").font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let url = connections.browserURL {
                    Link("認証ページを開く", destination: url).font(.caption)
                }
                if let prompt = connections.prompt {
                    Text(prompt.message).font(.caption)
                    if prompt.type == "select", let options = prompt.options {
                        Picker("選択", selection: $loginSelection) {
                            Text("選択してください").tag("")
                            ForEach(options) { option in Text(option.label).tag(option.id) }
                        }
                        Button("続行") { connections.submitPrompt(loginSelection); loginSelection = "" }
                            .disabled(loginSelection.isEmpty)
                    } else {
                        TextField(prompt.placeholder ?? "認証コードまたはURL", text: $loginInput)
                            .textFieldStyle(.roundedBorder)
                        Button("続行") { connections.submitPrompt(loginInput); loginInput = "" }
                            .disabled(loginInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if connections.activeCommand == "login" {
                    Button("接続を中止", action: connections.cancelLogin)
                        .font(.caption)
                }
            }
            if let error = connections.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct ProjectWorkspaceView: View {
    private enum InspectorTab: String, CaseIterable {
        case specification = "仕様"
        case result = "成果物"
    }

    @ObservedObject var model: WorkspaceModel
    @ObservedObject var connections: ProviderConnectionStore
    let availableSkills: [AgentSkill]
    let skillCatalogError: String?
    let refreshSkills: () -> Void
    @State private var inspectorTab: InspectorTab = .result
    @State private var highlightedSkillIndex = 0
    @State private var isImageDropTargeted = false
    @State private var chatFocused = false

    private var modelAvailable: Bool { connections.displayName(for: model.modelID) != nil }
    private var needsImageModel: Bool { !model.pendingImages.isEmpty || model.messages.contains(where: { !$0.attachments.isEmpty }) }

    private var skillSuggestions: [AgentSkill] {
        let input = model.chatInput
        guard input.hasPrefix("/"), !input.dropFirst().contains(where: { $0.isWhitespace }) else { return [] }
        let entered = String(input.dropFirst())
        let query = entered.hasPrefix("skill:") ? String(entered.dropFirst(6)) : entered
        return Array(availableSkills.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(8))
    }

    private var isSearchingSkills: Bool {
        model.chatInput.hasPrefix("/") && !model.chatInput.dropFirst().contains(where: { $0.isWhitespace })
    }

    private func completeSkill(_ skill: AgentSkill) {
        model.chatInput = "/\(skill.name) "
        highlightedSkillIndex = 0
        chatFocused = true
    }

    private func submitChat() {
        if isSearchingSkills, !skillSuggestions.isEmpty {
            completeSkill(skillSuggestions[min(highlightedSkillIndex, skillSuggestions.count - 1)])
        } else {
            sendChat()
        }
    }

    private func sendChat() {
        if case .selected(let skill, _) = AgentSkillCatalog.resolve(model.chatInput, among: availableSkills) {
            model.sendMessage(selectedSkill: skill)
        } else {
            model.sendMessage()
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            chatPane
                .frame(minWidth: 260, idealWidth: 340, maxWidth: 460)
            Divider()
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            inspectorPane
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 460)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("保存先", action: model.chooseOutputDirectory)
                if !model.jsonText.isEmpty {
                    Button("仕様を確認") { inspectorTab = .specification }
                }
                Button(model.isResponding ? "応答中…" : "仕様案を作る", action: model.proposeDraft)
                    .disabled(model.isResponding || !modelAvailable || model.pendingDraft != nil || !model.messages.contains(where: { $0.role == .user }))
            }
        }
        .onChange(of: model.jsonText) { _, newValue in
            if !newValue.isEmpty { inspectorTab = .specification }
        }
        .frame(maxHeight: .infinity)
    }

    private var inspectorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("作業パネル", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(16)
            Divider()
            if inspectorTab == .specification {
                if model.jsonText.isEmpty {
                    ContentUnavailableView("画面仕様案はまだありません", systemImage: "doc.text", description: Text("会話から仕様案を作るか、仕様ファイルを開いてください。"))
                } else {
                    draftReview
                }
            } else {
                resultPane
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var chatPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.name)
                .font(.title2.bold())
                .lineLimit(2)
            Text("エージェントと相談")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                ForEach(connections.providers.filter(\.connected)) { provider in
                    Section(provider.name) {
                        ForEach(provider.models) { candidate in
                            Button(candidate.name) { model.modelID = "\(provider.id)/\(candidate.id)" }
                        }
                    }
                }
            } label: {
                HStack {
                    Text(connections.displayName(for: model.modelID) ?? "モデルを選択")
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                }
                .font(.caption)
            }
            .disabled(connections.availableModels.isEmpty)
            .accessibilityLabel("利用するモデル")
            if !modelAvailable {
                Text(connections.isLoggedOut(modelID: model.modelID)
                     ? "ログアウト済み。この案件の手順は一時停止中です。再ログインすると再試行できます。"
                     : "左のモデルプロバイダーから接続し、モデルを選んでください。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if needsImageModel && modelAvailable && !connections.supportsImages(modelID: model.modelID) {
                Text("この会話には画像があります。画像対応モデルを選んでください。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            HStack {
                                if message.role == .user { Spacer(minLength: 30) }
                                VStack(alignment: .leading, spacing: 8) {
                                    if !message.text.isEmpty {
                                        Text(message.text)
                                            .font(.body)
                                            .textSelection(.enabled)
                                    }
                                    if !message.attachments.isEmpty {
                                        MessageAttachmentStrip(attachments: message.attachments)
                                    }
                                    if message.text.isEmpty && message.attachments.isEmpty {
                                        Text("空のメッセージ")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                    .padding(11)
                                    .background(message.role == .user ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                if message.role == .assistant { Spacer(minLength: 30) }
                            }
                            .id(message.id)
                        }
                        if model.isResponding {
                            ProgressView("エージェントが応答中")
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onAppear {
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if let approval = model.pendingToolApproval {
                VStack(alignment: .leading, spacing: 8) {
                    Label("スキルが操作の許可を求めています: \(approval.toolName)", systemImage: "hand.raised")
                        .font(.caption.weight(.semibold))
                    ScrollView {
                        Text(approval.arguments)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                    HStack {
                        Button("拒否") { model.resolveToolApproval(false) }
                        Button("この操作を許可") { model.resolveToolApproval(true) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            }
            Divider()
            if isSearchingSkills {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("エージェントスキル")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("更新", action: refreshSkills)
                            .font(.caption)
                    }
                    if let skillCatalogError {
                        Text(skillCatalogError).font(.caption2).foregroundStyle(.red)
                    }
                    if skillSuggestions.isEmpty {
                        Text("一致するスキルがありません（~/.agents/skills）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(skillSuggestions.enumerated()), id: \.element.id) { index, skill in
                            Button { completeSkill(skill) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("/\(skill.name)")
                                        .font(.caption.weight(index == highlightedSkillIndex ? .semibold : .regular))
                                    if !skill.description.isEmpty {
                                        Text(skill.description)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(5)
                                .background(index == highlightedSkillIndex ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .help(skill.fileURL.path)
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }
            imageAttachmentTray
            ZStack(alignment: .topLeading) {
                ChatComposer(
                    text: $model.chatInput,
                    isFocused: $chatFocused,
                    onSubmit: submitChat,
                    onMoveSuggestion: { direction in
                        guard isSearchingSkills, !skillSuggestions.isEmpty else { return false }
                        highlightedSkillIndex = min(max(highlightedSkillIndex + direction, 0), skillSuggestions.count - 1)
                        return true
                    },
                    onCompleteSuggestion: {
                        guard isSearchingSkills, !skillSuggestions.isEmpty else { return false }
                        completeSkill(skillSuggestions[min(highlightedSkillIndex, skillSuggestions.count - 1)])
                        return true
                    }
                )
                .frame(height: 112)
                if model.chatInput.isEmpty {
                    Text("依頼や修正を入力")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 13)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            .onChange(of: model.chatInput) { _, _ in highlightedSkillIndex = 0 }
            Text("Enter 送信 · Shift+Enter 改行")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack {
                Text(model.chatInput.hasPrefix("/")
                     ? "スキル外のファイル操作とシェル実行は操作ごとに確認します。"
                     : "通常の会話ではファイルやシェルを操作しません。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("送信", action: sendChat)
                    .disabled(model.isResponding || model.isImportingImages || !modelAvailable || (needsImageModel && !connections.supportsImages(modelID: model.modelID)) || (model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.pendingImages.isEmpty))
            }
        }
        .padding(16)
    }

    private var imageAttachmentTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: isImageDropTargeted ? "arrow.down.circle.fill" : "photo.on.rectangle.angled")
                    .foregroundStyle(isImageDropTargeted ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isImageDropTargeted ? "ここに画像をドロップ" : "画像を添付")
                        .font(.caption.weight(.semibold))
                    Text("Finderからドラッグ＆ドロップ、またはファイルを選択")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("ファイルを選択", action: chooseImages)
                    .font(.caption)
                    .controlSize(.small)
            }
            if !model.pendingImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingImages) { attachment in
                            PendingAttachmentTile(attachment: attachment) {
                                model.removePendingImage(attachment.id)
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            if model.isImportingImages {
                ProgressView("画像を読み込み中")
                    .controlSize(.small)
                    .font(.caption2)
            }
            if let attachmentError = model.attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(9)
        .background(isImageDropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(isImageDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $isImageDropTargeted, perform: handleImageDrop)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("画像を添付。Finderから画像をドロップできます")
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.prompt = "添付"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            model.addImage(from: url)
        }
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let item = item as? URL {
                        url = item
                    } else if let item = item as? NSURL {
                        url = item as URL
                    } else if let item = item as? Data {
                        url = URL(dataRepresentation: item, relativeTo: nil)
                    } else {
                        url = nil
                    }
                    guard let url else { return }
                    Task { @MainActor in
                        model.addImage(from: url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        model.addImage(data: data, name: "ドロップ画像")
                    }
                }
            }
        }
        return accepted
    }

    private var draftReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("画面仕様案")
                .font(.title2.bold())
            Text("会話とプレビューを見ながら、何を確かめるかを確認できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("プレビューで動くのは画面遷移と入力値の表示です。本文の切替や保存処理は含まれません。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let pending = model.pendingDraft {
                VStack(alignment: .leading, spacing: 8) {
                    Label("編集中に届いた改訂案があります。現在の仕様は上書きしていません。", systemImage: "doc.badge.clock")
                        .font(.caption)
                    DisclosureGroup("改訂案を確認") {
                        if let proposed = WireframeReviewSpec.read(pending) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(proposed.title).font(.headline)
                                Text(proposed.brief.learningGoal).font(.caption)
                                ForEach(proposed.screens) { screen in
                                    Text("• \(screen.name)：\(screen.purpose)").font(.caption)
                                }
                            }
                        } else {
                            Text("改訂案を読み取れません。破棄して再作成してください。")
                                .font(.caption)
                        }
                    }
                    HStack {
                        Button("改訂案を適用", action: model.applyPendingDraft)
                            .disabled(!modelAvailable || WireframeReviewSpec.read(pending) == nil)
                        Button("破棄", action: model.discardPendingDraft)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let spec = WireframeReviewSpec.read(model.jsonText) {
                        reviewContent(spec)
                    } else {
                        Label("仕様を読み取れません。詳細データを修正するか、チャットで作り直してください。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    DisclosureGroup("詳細データを表示・編集") {
                        TextEditor(text: $model.jsonText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 220)
                            .accessibilityLabel("画面仕様の詳細データ")
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            Divider()
            Text("修正したい点")
                .font(.headline)
            TextField("例：確認画面に所要時間を表示して", text: $model.revisionText, axis: .vertical)
                .lineLimit(2...3)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("仕様の修正指示")
            VStack(alignment: .leading, spacing: 10) {
                Button(model.isResponding ? "改訂中…" : "修正案を作る") {
                    let instruction = model.revisionText
                    model.revisionText = ""
                    model.reviseDraft(instruction)
                }
                .disabled(model.isResponding || !modelAvailable || model.pendingDraft != nil || model.jsonText.isEmpty || model.revisionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("この内容でプレビューを作る", action: model.build)
                    .buttonStyle(.borderedProminent)
                    .disabled(!modelAvailable || model.isResponding || model.isBuilding || WireframeReviewSpec.read(model.jsonText)?.reviewIssues.isEmpty != true)
            }
        }
        .padding(16)
    }

    private func reviewContent(_ spec: WireframeReviewSpec) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(spec.title).font(.title3.bold())
                    Spacer()
                    Text(spec.status).font(.caption).foregroundStyle(.secondary)
                }
                reviewRow("対象ユーザー", spec.brief.targetUser)
                reviewRow("困っていること", spec.brief.problem)
                reviewRow("利用者ができるようになること", spec.brief.userOutcome)
                reviewRow("事業側で知りたいこと", spec.brief.businessOutcome)
                reviewRow("検証したいこと", spec.brief.learningGoal)
                reviewRow("試す仮説", spec.brief.hypothesis)
                reviewRow("最も不確かな前提", spec.brief.riskiestAssumption)
                reviewRow("今回の範囲", spec.brief.solutionBoundary)
                if let palette = spec.palette {
                    let color = palette.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let colorName = ["gray", "grey", "slate"].contains(color) ? "グレー系"
                        : color == "indigo" ? "藍色系"
                        : color == "teal" ? "青緑系" : "未対応（\(palette)）"
                    reviewRow("配色", colorName)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

            if !spec.decisions.isEmpty {
                reviewList("判断してほしい点", items: spec.decisions, symbol: "questionmark.circle")
            }

            if !spec.reviewIssues.isEmpty {
                reviewList("生成前に修正が必要", items: spec.reviewIssues, symbol: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            operationReview(model.operationReport, title: "プレビューで確かめられる操作")

            VStack(alignment: .leading, spacing: 10) {
                Text("画面と操作の流れ").font(.headline)
                ForEach(Array(spec.screens.enumerated()), id: \.element.id) { index, screen in
                    screenCard(screen, number: index + 1, spec: spec)
                }
            }

            if !spec.assumptions.isEmpty || !spec.openQuestions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    if !spec.assumptions.isEmpty {
                        reviewList("仮定", items: spec.assumptions, symbol: "info.circle")
                    }
                    if !spec.openQuestions.isEmpty {
                        reviewList("未解決", items: spec.openQuestions, symbol: "exclamationmark.circle")
                        Text("未解決の点をチャットで確かめるか、仮のままプレビューを作れます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func screenCard(_ screen: WireframeReviewSpec.Screen, number: Int, spec: WireframeReviewSpec) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(number). \(screen.name)").font(.headline)
            Text(screen.purpose)
            ForEach(Array(screen.blocks.enumerated()), id: \.offset) { _, block in
                if let description = blockDescription(block) {
                    Text(description).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(screen.actions.enumerated()), id: \.offset) { _, action in
                Label("\(action.label) → \(spec.screenName(for: action.target))", systemImage: "arrow.right.circle")
                    .font(.subheadline)
            }
            Text("確認する点：\(screen.testNote)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func blockDescription(_ block: WireframeReviewSpec.Block) -> String? {
        switch block.type {
        case "panel": return "説明：\(block.title ?? "") — \(block.text ?? "")"
        case "paragraph": return "文章：\(block.text ?? "")"
        case "field":
            let kind = ["textarea", "multiline", "multi-line", "long-text"].contains(block.resolvedInputType) ? "複数行入力" : "入力"
            let inferred = block.inferredInputType ? "（形式を自動設定）" : ""
            return "\(kind)：\(block.label ?? "")\(inferred)\(block.placeholder.map { "（例：\($0)）" } ?? "")"
        case "select": return "選択：\(block.label ?? "")（\(block.options?.joined(separator: "／") ?? "")）"
        case "value": return "表示：\(block.label ?? "")"
        case "list": return "一覧：\(block.items?.joined(separator: "／") ?? "")"
        default: return "未対応の項目：\(block.type)"
        }
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func reviewList(_ title: String, items: [String], symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            ForEach(items, id: \.self) { item in
                Label(item, systemImage: symbol)
            }
        }
    }

    @ViewBuilder
    private func operationReview(_ report: OperationCapabilityReport?, title: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if report == nil && model.operationAnalysisError == nil {
                    ProgressView().controlSize(.small)
                }
            }
            if let report {
                if report.isFreeform {
                    Label("操作の宣言がありません。画面上の操作だけを列挙し、自由文の動作は照合していません。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(report.operations) { operation in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: operation.symbolName)
                                .foregroundStyle(operation.status == "working" ? .green : operation.status == "unsupported" ? .red : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(operation.label).font(.subheadline.weight(.medium))
                                if let expectedResult = operation.expectedResult {
                                    Text("期待する結果：\(expectedResult)")
                                        .font(.caption)
                                }
                                Text("\(operation.statusLabel)：\(operation.reason)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                if report.unsupportedCount > 0 {
                        Label("未対応の操作があります。プレビューの生成は続けられます。", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                }
            } else if let error = model.operationAnalysisError {
                Label("操作の自動確認を利用できません。仕様の確認と生成は続けられます。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(error)
            } else {
                Text("仕様の操作を確認しています…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("プレビュー").font(.title2.bold())
                Spacer()
                if model.isBuilding { ProgressView().controlSize(.small) }
            }
            .padding(16)
            if let report = model.artifactOperationReport {
                operationPreviewSummary(report)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if model.artifactURL != nil && (model.artifactSourceRevision != model.specRevision || model.isBuilding || model.hasBuildFailure) {
                Label("表示中のプレビューは前回の生成結果です。", systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if let artifact = model.artifactURL {
                PreviewView(fileURL: artifact)
                    .id(artifact)
            } else {
                ContentUnavailableView("プレビューはまだありません", systemImage: "rectangle.on.rectangle", description: Text("チャットで相談し、画面仕様案を確認してから生成します。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func operationPreviewSummary(_ report: OperationCapabilityReport) -> some View {
        HStack(spacing: 7) {
            Image(systemName: report.unsupportedCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(report.unsupportedCount == 0 ? .green : .orange)
            if report.isFreeform {
                Text("画面上の操作のみ分類。自由文の動作は未照合です")
            } else if report.unsupportedCount == 0 {
                Text("宣言された操作の実装範囲を表示中（\(report.operations.count)件）")
            } else {
                Text("未対応の操作 \(report.unsupportedCount)件を含む成果物です")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var resultPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("成果物").font(.title2.bold())
            Text(model.status)
                .font(.subheadline)
            if (model.piJobState == .failed || model.piJobState == .interrupted) && model.canRetryPi {
                Button("エージェントの処理を再試行", action: model.retryPi)
                    .disabled(!modelAvailable)
            }
            if model.hasBuildFailure || model.buildJobState == .interrupted {
                Button("この案件の仕様で再試行", action: model.build)
                    .disabled(!modelAvailable || model.isBuilding)
            }
            if let artifact = model.artifactURL {
                Text(artifact.lastPathComponent)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("Finderで表示") {
                    NSWorkspace.shared.activateFileViewerSelecting([artifact])
                }
            }
            Divider()
            Text("保存先").font(.headline)
            Text(model.outputDirectory.path)
                .font(.caption)
                .textSelection(.enabled)
            Divider()
            Text("実行ログ").font(.headline)
            ScrollView {
                Text(model.transcript.isEmpty ? "実行後に表示します。" : model.transcript)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity)
    }
}

private struct MessageAttachmentStrip: View {
    let attachments: [ChatImageAttachment]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    AttachmentPreview(attachment: attachment)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

private struct PendingAttachmentTile: View {
    let attachment: ChatImageAttachment
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AttachmentPreview(attachment: attachment)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.7))
            }
            .buttonStyle(.plain)
            .padding(3)
            .accessibilityLabel("添付を削除: \(attachment.name)")
        }
    }
}

private struct AttachmentPreview: View {
    let attachment: ChatImageAttachment

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if let image = NSImage(contentsOf: attachment.fileURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 68, height: 54)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(attachment.name)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
        }
        .help(attachment.name)
        .accessibilityLabel("添付画像: \(attachment.name)")
    }
}
