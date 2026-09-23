import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ChatImageAttachment: Identifiable, Codable, Sendable {
    let id: UUID
    let name: String
    let fileURL: URL
    let mimeType: String
}

enum ChatImageAttachmentError: LocalizedError {
    case unsupported
    case tooLarge
    case tooMany
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "画像を読み込めません。JPEG、PNG、HEICなどの画像を選んでください。"
        case .tooLarge: "画像は1枚20MB以下にしてください。"
        case .tooMany: "一度に添付できる画像は8枚までです。"
        case .missing(let name): "添付画像「\(name)」が見つかりません。もう一度添付してください。"
        }
    }
}

enum ChatImageAttachmentStore {
    static func importFile(_ url: URL, projectID: UUID) throws -> ChatImageAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        if let size, size > 20_000_000 { throw ChatImageAttachmentError.tooLarge }
        return try importData(Data(contentsOf: url), name: url.lastPathComponent, projectID: projectID)
    }

    static func importData(_ data: Data, name: String, projectID: UUID) throws -> ChatImageAttachment {
        guard data.count <= 20_000_000 else { throw ChatImageAttachmentError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeID = CGImageSourceGetType(source),
              let type = UTType(typeID as String), type.conforms(to: .image),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ChatImageAttachmentError.unsupported
        }
        let isJPEG = type.conforms(to: .jpeg)
        let isPNG = type.conforms(to: .png) && (CGImageSourceGetCount(source) == 1)
        let output: Data
        let ext: String
        let mime: String
        if isJPEG || isPNG {
            output = data
            ext = isJPEG ? "jpg" : "png"
            mime = isJPEG ? "image/jpeg" : "image/png"
        } else {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let converted = CFDataCreateMutable(nil, 0),
                  let destination = CGImageDestinationCreateWithData(converted, UTType.png.identifier as CFString, 1, nil) else {
                throw ChatImageAttachmentError.unsupported
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ChatImageAttachmentError.unsupported }
            output = converted as Data
            ext = "png"
            mime = "image/png"
        }
        guard output.count <= 20_000_000 else { throw ChatImageAttachmentError.tooLarge }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Agent Workspace/projects/\(projectID.uuidString)/attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let id = UUID()
        let fileURL = base.appendingPathComponent("\(id.uuidString).\(ext)")
        try output.write(to: fileURL, options: .atomic)
        return ChatImageAttachment(id: id, name: name, fileURL: fileURL, mimeType: mime)
    }
}
