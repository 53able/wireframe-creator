import AppKit
import Combine
import Foundation

struct ProviderModel: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let supportsImages: Bool?
}

struct ModelProvider: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let connected: Bool
    let models: [ProviderModel]
}

struct LoginPrompt: Codable, Equatable {
    struct Option: Codable, Identifiable, Equatable {
        let id: String
        let label: String
    }

    let type: String
    let message: String
    let placeholder: String?
    let options: [Option]?
}

private struct BridgeMessage: Decodable {
    struct Event: Decodable {
        let type: String
        let message: String?
        let url: String?
        let instructions: String?
        let userCode: String?
        let verificationUri: String?
    }

    let kind: String
    let providers: [ModelProvider]?
    let event: Event?
    let id: String?
    let prompt: LoginPrompt?
    let message: String?
}

@MainActor
final class ProviderConnectionStore: ObservableObject {
    @Published private(set) var providers: [ModelProvider] = [
        ModelProvider(id: "openai-codex", name: "OpenAI Codex", connected: false, models: []),
        ModelProvider(id: "anthropic", name: "Anthropic", connected: false, models: [])
    ]
    @Published private(set) var activeProviderID: String?
    @Published private(set) var activeCommand: String?
    @Published private(set) var isLoading = false
    @Published private(set) var prompt: LoginPrompt?
    @Published private(set) var browserURL: URL?
    @Published private(set) var deviceCode: String?
    @Published private(set) var progress: String?
    @Published private(set) var errorMessage: String?

    private var process: Process?
    private var input: FileHandle?
    private var promptID: String?
    private var runID: UUID?
    private var completed = false
    private var blockedProviderIDs = Set(UserDefaults.standard.stringArray(forKey: "loggedOutProviderIDs") ?? [])

    init() { refresh() }

    var availableModels: [(provider: ModelProvider, model: ProviderModel)] {
        providers.filter(\.connected).flatMap { provider in
            provider.models.map { (provider, $0) }
        }
    }

    func displayName(for modelID: String) -> String? {
        availableModels.first(where: { "\($0.provider.id)/\($0.model.id)" == modelID })
            .map { "\($0.provider.name) · \($0.model.name)" }
    }

    func supportsImages(modelID: String) -> Bool {
        availableModels.first(where: { "\($0.provider.id)/\($0.model.id)" == modelID })?.model.supportsImages ?? false
    }

    func isLoggedOut(modelID: String) -> Bool {
        guard let providerID = modelID.split(separator: "/", maxSplits: 1).first else { return false }
        return blockedProviderIDs.contains(String(providerID))
    }

    func refresh() { start(command: "catalog", providerID: nil) }

    func connect(_ providerID: String) {
        guard activeProviderID == nil else { return }
        start(command: "login", providerID: providerID)
    }

    func disconnect(_ providerID: String) {
        if process != nil { cancelLogin() }
        blockedProviderIDs.insert(providerID)
        persistBlockedProviders()
        providers = filteredProviders(providers)
        start(command: "logout", providerID: providerID)
    }

    func submitPrompt(_ value: String) {
        guard let promptID, let input else { return }
        let reply = ["id": promptID, "value": value]
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        input.write(data + Data([0x0A]))
        self.promptID = nil
        prompt = nil
        progress = "認証を確認中…"
    }

    func cancelLogin() {
        if process?.isRunning == true { process?.terminate() }
        process = nil
        runID = nil
        input = nil
        prompt = nil
        promptID = nil
        activeProviderID = nil
        activeCommand = nil
        isLoading = false
        progress = "認証を中止しました"
    }

    private func start(command: String, providerID: String?) {
        guard process == nil else { return }
        let token = UUID()
        runID = token
        completed = false
        errorMessage = nil
        prompt = nil
        promptID = nil
        browserURL = nil
        deviceCode = nil
        progress = nil
        activeProviderID = providerID
        activeCommand = command
        isLoading = true
        do {
            let node = try RuntimeTools.find("node")
            let resourceRoot = WorkspaceResources.repository
            let script = resourceRoot.appendingPathComponent("scripts/provider-bridge.mjs")
            guard FileManager.default.fileExists(atPath: script.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let child = Process()
            child.executableURL = node
            child.arguments = [script.path, command] + (providerID.map { [$0] } ?? [])
            child.currentDirectoryURL = resourceRoot
            child.environment = RuntimeTools.environment(prepending: node.deletingLastPathComponent())
            let stdin = Pipe()
            let stdout = Pipe()
            child.standardInput = stdin
            child.standardOutput = stdout
            child.standardError = FileHandle.nullDevice
            try child.run()
            process = child
            input = stdin.fileHandleForWriting
            let reader = stdout.fileHandleForReading
            Task.detached { [weak self] in
                var pending = Data()
                while true {
                    let chunk = reader.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        await self?.receive(line, token: token)
                    }
                }
                child.waitUntilExit()
                await self?.finish(token: token, exitCode: child.terminationStatus)
            }
        } catch {
            isLoading = false
            activeProviderID = nil
            activeCommand = nil
            errorMessage = "モデル接続を開始できません: \(error.localizedDescription)"
        }
    }

    private func receive(_ line: Data, token: UUID) {
        guard runID == token, let message = try? JSONDecoder().decode(BridgeMessage.self, from: line) else { return }
        switch message.kind {
        case "complete":
            if activeCommand == "login", let providerID = activeProviderID {
                blockedProviderIDs.remove(providerID)
                persistBlockedProviders()
            }
            if let providers = message.providers { self.providers = filteredProviders(providers) }
            completed = true
            progress = activeCommand == "logout" ? "ログアウトしました" : (activeProviderID == nil ? nil : "接続しました")
        case "error":
            errorMessage = message.message ?? "認証に失敗しました"
        case "prompt":
            prompt = message.prompt
            promptID = message.id
            progress = nil
        case "event":
            guard let event = message.event else { return }
            switch event.type {
            case "auth_url":
                if let text = event.url, let url = URL(string: text), url.scheme == "https" {
                    browserURL = url
                    NSWorkspace.shared.open(url)
                }
                progress = event.instructions ?? "ブラウザーで認証を続けてください"
            case "device_code":
                deviceCode = event.userCode
                if let text = event.verificationUri, let url = URL(string: text), url.scheme == "https" {
                    browserURL = url
                    NSWorkspace.shared.open(url)
                }
                progress = "ブラウザーでコードを入力してください"
            case "progress", "info":
                progress = event.message
            default: break
            }
        default: break
        }
    }

    private func finish(token: UUID, exitCode: Int32) {
        guard runID == token else { return }
        process = nil
        input = nil
        prompt = nil
        promptID = nil
        activeProviderID = nil
        activeCommand = nil
        isLoading = false
        if exitCode != 0 && errorMessage == nil { errorMessage = "認証を完了できませんでした（終了コード \(exitCode)）" }
        if exitCode == 0 && !completed { errorMessage = "モデル一覧を取得できませんでした" }
    }

    private func filteredProviders(_ candidates: [ModelProvider]) -> [ModelProvider] {
        candidates.map { provider in
            blockedProviderIDs.contains(provider.id)
                ? ModelProvider(id: provider.id, name: provider.name, connected: false, models: [])
                : provider
        }
    }

    private func persistBlockedProviders() {
        UserDefaults.standard.set(Array(blockedProviderIDs).sorted(), forKey: "loggedOutProviderIDs")
    }
}
