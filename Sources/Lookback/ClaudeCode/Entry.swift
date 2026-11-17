import Foundation

struct Entry {
    let id: String
    let type: String
    let parent: String?
    let timestamp: String
    let sidechain: Bool
    let agent: String?
    let sourceAssistant: String?
    let response: String?
    let message: SessionMessage?
    let calls: [String]
    let results: [String]
    let carriesResult: Bool

    var isMessage: Bool { type == "user" || type == "assistant" }

    init?(_ row: Row) {
        guard let id = row["uuid"] as? String, let type = row["type"] as? String,
              ["assistant", "user", "system", "attachment", "progress"].contains(type) else { return nil }
        self.id = id
        self.type = type
        parent = row["parentUuid"] as? String
        timestamp = row["timestamp"] as? String ?? ""
        sidechain = row["isSidechain"] as? Bool == true
        agent = row["agentId"] as? String
        sourceAssistant = row["sourceToolAssistantUUID"] as? String
        let body = row["message"] as? Row
        let messageID = body?["id"] as? String
        response = type == "assistant" && messageID != "" ? messageID : nil
        let content = (body?["content"] as? [Any] ?? []).compactMap { $0 as? Row }
        calls = content.compactMap { $0["type"] as? String == "tool_use" ? $0["id"] as? String : nil }
        results = content.compactMap { $0["type"] as? String == "tool_result" ? $0["tool_use_id"] as? String : nil }
        carriesResult = content.contains { $0["type"] as? String == "tool_result" }
        guard type == "user" || type == "assistant", !sidechain, row["isMeta"] as? Bool != true,
              (row["teamName"] as? String ?? "").isEmpty else {
            message = nil
            return
        }
        let blocks = (body?["content"] as? String).map { [MessageBlock.text($0)] } ?? content.map(Self.block)
        let compact = row["isCompactSummary"] as? Bool == true
        let role: MessageRole
        if compact { role = .system }
        else if type == "assistant" { role = .assistant }
        else if carriesResult { role = .tool }
        else { role = .user }
        message = SessionMessage(id: id, parentID: parent, timestamp: transcriptDate(timestamp),
                                 role: role, blocks: blocks, isCompactionSummary: compact)
    }

    func sameWriter(as other: Entry) -> Bool {
        sidechain == other.sidechain && agent == other.agent
    }

    private static func block(_ data: Row) -> MessageBlock {
        let type = data["type"] as? String ?? "unknown"
        switch type {
        case "text":
            if let text = data["text"] as? String { return .text(text) }
        case "tool_use":
            if let id = data["id"] as? String, let name = data["name"] as? String {
                return .toolCall(id: id, name: name, inputJSON: json(data["input"]))
            }
        case "tool_result":
            if let id = data["tool_use_id"] as? String {
                return .toolResult(callID: id, contentJSON: json(data["content"]), isError: data["is_error"] as? Bool == true)
            }
        default: break
        }
        return .other(type: type)
    }

    private static func json(_ value: Any?) -> Data? {
        guard let value else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }
}
