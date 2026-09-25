import Foundation

struct WireframeReviewSpec: Decodable {
    struct Brief: Decodable {
        let targetUser: String
        let problem: String
        let userOutcome: String
        let businessOutcome: String
        let solutionBoundary: String
        let hypothesis: String
        let riskiestAssumption: String
        let learningGoal: String
    }

    struct Block: Decodable {
        let type: String
        let title: String?
        let text: String?
        let label: String?
        let options: [String]?
        let items: [String]?
        let placeholder: String?
        let inputType: String?

        var resolvedInputType: String {
            let type = inputType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if !type.isEmpty { return type }
            let name = label ?? ""
            let longForm = "本文|内容|メモ|説明|コメント|diary|body|description|message"
            return name.range(of: longForm, options: [.regularExpression, .caseInsensitive]) == nil ? "text" : "textarea"
        }

        var inferredInputType: Bool {
            inputType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
    }

    struct Action: Decodable {
        let label: String
        let target: String
    }

    struct Screen: Decodable, Identifiable {
        let id: String
        let name: String
        let purpose: String
        let testNote: String
        let blocks: [Block]
        let actions: [Action]
    }

    let title: String
    let status: String
    let palette: String?
    let brief: Brief
    let decisions: [String]
    let assumptions: [String]
    let openQuestions: [String]
    let screens: [Screen]

    static func read(_ json: String) -> WireframeReviewSpec? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func screenName(for id: String) -> String {
        screens.first(where: { $0.id == id })?.name ?? "遷移先未設定（\(id)）"
    }

    var reviewIssues: [String] {
        var issues: [String] = []
        if !["slate", "gray", "grey", "indigo", "teal"].contains(palette?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "") {
            issues.append("配色が未指定、または未対応です。")
        }
        if screens.isEmpty { issues.append("画面がありません。") }
        let ids = Set(screens.map(\.id))
        for screen in screens {
            for block in screen.blocks where block.type == "field" {
                let type = block.resolvedInputType
                let supported = ["text", "textarea", "multiline", "multi-line", "long-text", "email", "number", "search", "date", "time", "datetime-local", "tel", "url"]
                if !supported.contains(type) {
                    issues.append("「\(screen.name)」の「\(block.label ?? "入力欄")」の入力形式「\(type)」は未対応です。")
                }
            }
            for action in screen.actions where !ids.contains(action.target) {
                issues.append("「\(screen.name)」からの遷移先「\(action.target)」が見つかりません。")
            }
        }
        return issues
    }
}
