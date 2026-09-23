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
