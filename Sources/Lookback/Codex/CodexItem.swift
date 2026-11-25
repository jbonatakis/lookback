import Foundation

/// Codex may persist the same visible message as model input, a display event, and a completed UI item.
struct CodexItem {
    enum Representation: Int { case response, display, completed }

    let role: MessageRole
    let blocks: [MessageBlock]
    let nativeID: String?
    let representation: Representation
    var summary = false
    var toolEvents: [SessionToolEvent] = []

    init(_ role: MessageRole, _ blocks: [MessageBlock], _ id: String?, _ representation: Representation = .response) {
        self.role = role
        self.blocks = blocks
        nativeID = id.flatMap { $0.isEmpty ? nil : $0 }
        self.representation = representation
    }

    var text: String? {
        let parts = blocks.compactMap { if case let .text(value) = $0 { value } else { nil } }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    struct ToolKey: Hashable {
        let id: String
        let output: Bool
    }

    var toolKey: ToolKey? {
        switch blocks.first {
        case let .toolCall(id, _, _): ToolKey(id: id, output: false)
        case let .toolResult(id, _, _): ToolKey(id: id, output: true)
        default: nil
        }
    }

    /// UI tool completions also occur in rollouts that omit the corresponding model call or output.
    static func completedTool(_ event: Row) -> [CodexItem] {
        let body = event["item"] as? Row ?? event
        guard let id = (body["call_id"] ?? body["id"]) as? String else { return [] }
        let name: String
        let input: Any?
        let output: Any?
        switch body["type"] as? String {
        case "CommandExecution", "exec_command_end":
            name = "exec_command"
            input = body["command"]
            output = body["aggregated_output"] ?? body["formatted_output"]
        case "McpToolCall", "mcp_tool_call_end":
            let invocation = body["invocation"] as? Row ?? body
            guard let tool = invocation["tool"] as? String else { return [] }
            name = tool
            input = invocation["arguments"]
            output = body["result"]
        case "FileChange", "patch_apply_end":
            name = "apply_patch"
            input = body["changes"]
            output = body.filter { $0.key == "stdout" || $0.key == "stderr" }
        default: return []
        }
        let status = (body["status"] as? String)?.lowercased()
        let result = output as? Row
        let failed = (body["exit_code"] as? Int).map { $0 != 0 } == true || body["success"] as? Bool == false
            || status == "failed" || result?["isError"] as? Bool == true || result?["Err"] != nil
        let rep: Representation = event["item"] != nil ? .completed : .display
        return [CodexItem(.assistant, [.toolCall(id: id, name: name, inputJSON: json(input))], id, rep),
                CodexItem(.tool, [.toolResult(callID: id, contentJSON: json(output), isError: failed)], nil, rep)]
    }

    static func completionEvent(_ payload: Row) -> SessionToolEvent? {
        guard payload["type"] as? String == "item_completed", let item = payload["item"] as? Row,
              let id = item["id"] as? String else { return nil }
        let failed = (item["status"] as? String)?.lowercased() == "failed"
        switch item["type"] as? String {
        case "CommandExecution":
            let input = item.filter { ["command", "parsed_cmd", "cwd"].contains($0.key) }
            return SessionToolEvent(id: id, name: "exec_command", inputJSON: json(input),
                                    outputJSON: json(item["aggregated_output"]), exitCode: item["exit_code"] as? Int, isError: failed)
        case "FileChange":
            return SessionToolEvent(id: id, name: "apply_patch", inputJSON: json(item["changes"]),
                                    outputJSON: nil, exitCode: nil, isError: failed)
        default: return nil
        }
    }

    private static func message(_ role: MessageRole, _ body: Row, _ representation: Representation) -> CodexItem? {
        let content = body["content"] as? [Row] ?? []
        let blocks: [MessageBlock] = content.compactMap { block in
            guard let type = block["type"] as? String else { return nil }
            switch type.lowercased() {
            case "text", "input_text", "output_text":
                guard let text = block["text"] as? String, !text.isEmpty else { return nil }
                if role == .user && representation == .response && isInjected(text) { return nil }
                return .text(text)
            default: return .other(type: type.lowercased())
            }
        }
        guard !blocks.isEmpty else { return nil }
        return CodexItem(role, blocks, body["id"] as? String, representation)
    }

    private static func isInjected(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["<environment_context>", "<user_instructions>", "# AGENTS.md instructions for ",
                "<turn_aborted>", "<subagent_notification>", "<permissions instructions>",
                "<collaboration_mode>", "<skill>", "<skills_instructions>"].contains(where: value.hasPrefix)
    }

    static func decode(type: String, payload: Row) -> CodexItem? {
        switch type {
        case "response_item": return response(payload)
        case "event_msg":
            switch payload["type"] as? String {
            case "item_completed":
                guard let item = payload["item"] as? Row else { return nil }
                switch item["type"] as? String {
                case "UserMessage", "userMessage": return message(.user, item, .completed)
                case "AgentMessage", "agentMessage": return message(.assistant, item, .completed)
                default: return nil
                }
            case "agent_message", "user_message":
                let user = payload["type"] as? String == "user_message"
                var blocks: [MessageBlock] = []
                if let value = payload["message"] as? String, !value.isEmpty { blocks.append(.text(value)) }
                if user {
                    for key in ["images", "local_images"] {
                        for _ in payload[key] as? [Any] ?? [] { blocks.append(.other(type: "image")) }
                    }
                }
                return blocks.isEmpty ? nil : CodexItem(user ? .user : .assistant, blocks, payload["id"] as? String, .display)
            default: return nil
            }
        default: return nil
        }
    }

    static func response(_ payload: Row) -> CodexItem? {
        let id = payload["id"] as? String
        let call = payload["call_id"] as? String
        switch payload["type"] as? String {
        case "message":
            switch payload["role"] as? String {
            case "assistant": return message(.assistant, payload, .response)
            case "user": return message(.user, payload, .response)
            default: return nil
            }
        case "function_call", "custom_tool_call":
            guard let call, let name = payload["name"] as? String else { return nil }
            let input: Data?
            if let string = payload["arguments"] as? String {
                let data = Data(string.utf8)
                input = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil ? data : json(string)
            } else {
                input = json(payload["input"] ?? payload["arguments"])
            }
            return CodexItem(.assistant, [.toolCall(id: call, name: name, inputJSON: input)], id)
        case "local_shell_call", "web_search_call":
            guard let callID = call ?? id, let name = payload["type"] as? String else { return nil }
            return CodexItem(.assistant, [.toolCall(id: callID, name: name, inputJSON: json(payload["action"]))], id)
        case "function_call_output", "custom_tool_call_output":
            guard let call else { return nil }
            let failed = payload["is_error"] as? Bool == true || payload["status"] as? String == "failed"
            return CodexItem(.tool, [.toolResult(callID: call, contentJSON: json(payload["output"]), isError: failed)], id)
        case "compaction":
            return marker(id: id, text: nil)
        default: return nil
        }
    }

    static func marker(id: String?, text: String?) -> CodexItem {
        let block: MessageBlock = text.flatMap { $0.isEmpty ? nil : .text($0) } ?? .other(type: "compaction")
        var item = CodexItem(.system, [block], id)
        item.summary = true
        return item
    }

    private static func json(_ value: Any?) -> Data? {
        guard let value else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }
}
