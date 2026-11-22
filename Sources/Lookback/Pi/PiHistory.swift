import Foundation

/// The on-disk tree contains prompt patches, labels and settings as well as messages.
struct PiHistory {
    private struct Node {
        let id: String
        let parent: String?
        let visibleAncestor: String?
        let position: Int?
        let firstKept: String?
        let edit: Edit?
    }
    private struct Edit {
        let target: String
        // Pi uses JSON null to omit a target. Otherwise the replacement supplies its content.
        let content: Any?
    }
    private var nodes: [String: Node] = [:]
    private var leaf: String?
    private var duplicate = false
    private var recorded: [SessionMessage] = []

    mutating func append(_ row: Row) {
        guard let type = row["type"] as? String, type != "session", let id = row["id"] as? String, !id.isEmpty,
              row["parentId"] is String || row["parentId"] is NSNull else { return }
        guard nodes[id] == nil else { duplicate = true; return }
        let parent = row["parentId"] as? String
        let ancestor = parent.flatMap { nodes[$0]?.visibleAncestor }
        var message: SessionMessage?
        var firstKept: String?
        var edit: Edit?
        switch type {
        case "message":
            if let body = row["message"] as? Row {
                message = Self.message(body, id: id, parent: ancestor, position: recorded.count, date: row["timestamp"] as? String)
            }
        case "compaction", "branch_summary":
            if type == "compaction" { firstKept = row["firstKeptEntryId"] as? String }
            if let summary = row["summary"] as? String {
                message = SessionMessage(id: id, parentID: ancestor, timestamp: transcriptDate(row["timestamp"] as? String),
                                         role: .system, blocks: [.text(summary)], isCompactionSummary: type == "compaction",
                                         recordedIndex: recorded.count)
            }
        case "context_edit":
            if let target = row["targetId"] as? String {
                if row["replacement"] is NSNull { edit = Edit(target: target, content: nil) }
                else if let replacement = row["replacement"] as? Row, let content = replacement["content"] {
                    edit = Edit(target: target, content: content)
                }
            }
        default: break
        }
        nodes[id] = Node(id: id, parent: parent, visibleAncestor: message?.id ?? ancestor, position: message?.recordedIndex,
                         firstKept: firstKept, edit: edit)
        if let message { recorded.append(message) }
        leaf = id
    }

    func finish(info: SessionInfo) throws -> SessionHistory {
        var path: [Node] = [], cursor = leaf, seen = Set<String>()
        guard !duplicate else { throw SessionReadError.incompleteHistory(info.id) }
        while let id = cursor {
            guard let node = nodes[id], seen.insert(id).inserted else { throw SessionReadError.incompleteHistory(info.id) }
            path.append(node)
            cursor = node.parent
        }
        path.reverse()
        let transcript = path.compactMap { $0.position.map { recorded[$0] } }

        // Only the newest compaction contributes a summary. The retained range can start on a metadata
        // entry, or at the compaction itself when Pi retains none of the preceding entries.
        var context = path[...]
        var summary: SessionMessage?
        if let boundary = path.lastIndex(where: { $0.firstKept != nil }), let firstKept = path[boundary].firstKept {
            summary = path[boundary].position.map { recorded[$0] }
            let start = path[..<boundary].firstIndex(where: { $0.id == firstKept }) ?? boundary
            context = path[start...]
        }
        var edits: [String: Edit] = [:]
        for node in context {
            if let edit = node.edit { edits[edit.target] = edit }
        }
        var conversation = summary.map { [$0] } ?? []
        for node in context {
            guard let position = node.position else { continue }
            let message = recorded[position]
            if message.isCompactionSummary { continue }
            if let edit = edits[message.id], message.role != .system {
                if let content = edit.content {
                    conversation.append(Self.replacingContent(of: message, with: content))
                }
            } else {
                conversation.append(message)
            }
        }
        return SessionHistory(id: info.id, conversation: conversation, recordedMessages: recorded, info: info, transcript: transcript)
    }

    private static func message(_ body: Row, id: String, parent: String?, position: Int, date: String?) -> SessionMessage? {
        let role: MessageRole, content: [MessageBlock]
        switch body["role"] as? String {
        case "user": role = .user; content = blocks(body["content"])
        case "assistant": role = .assistant; content = blocks(body["content"])
        case "toolResult":
            guard let callID = body["toolCallId"] as? String else { return nil }
            role = .tool
            content = [.toolResult(callID: callID, contentJSON: json(body["content"]), isError: body["isError"] as? Bool ?? false)]
        default: return nil
        }
        let timestamp = transcriptDate(date) ?? (body["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return SessionMessage(id: id, parentID: parent, timestamp: timestamp, role: role, blocks: content, recordedIndex: position)
    }

    private static func json(_ value: Any?) -> Data? {
        guard let value else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }

    static func blocks(_ content: Any?) -> [MessageBlock] {
        if let text = content as? String { return [.text(text)] }
        return (content as? [Any] ?? []).compactMap { item in
            guard let block = item as? Row, let type = block["type"] as? String else { return nil }
            switch type {
            case "text":
                if let value = block["text"] as? String { return .text(value) }
            case "toolCall":
                if let id = block["id"] as? String, let name = block["name"] as? String {
                    return .toolCall(id: id, name: name, inputJSON: json(block["arguments"]))
                }
            default: break
            }
            return .other(type: type)
        }
    }

    private static func replacingContent(of message: SessionMessage, with content: Any) -> SessionMessage {
        let replacement: [MessageBlock]
        if message.role == .tool, case let .toolResult(callID, _, isError) = message.blocks.first {
            let normalized: Any = (content as? String).map { [["type": "text", "text": $0]] as Any } ?? content
            replacement = [.toolResult(callID: callID, contentJSON: json(normalized), isError: isError)]
        } else {
            replacement = blocks(content)
        }
        return SessionMessage(id: message.id, parentID: message.parentID, timestamp: message.timestamp,
                              role: message.role, blocks: replacement, recordedIndex: message.recordedIndex)
    }
}
