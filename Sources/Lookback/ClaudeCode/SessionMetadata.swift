import Foundation

struct SessionMetadata {
    private var first = true
    private(set) var isSidechain = false
    private(set) var cwd: String?
    private(set) var branch: String?
    private(set) var createdAt: Date?
    private var custom: String?
    private var generated: String?
    private var lastPrompt: String?
    private var summary: String?
    private var firstPrompt: String?
    private var command: String?

    var title: String? { custom ?? generated ?? lastPrompt ?? summary ?? firstPrompt ?? command }

    func info(id: SessionID, modifiedAt: Date) -> SessionInfo? {
        guard !isSidechain, let title else { return nil }
        return SessionInfo(id: id, title: title, workingDirectory: cwd, gitBranch: branch,
                           createdAt: createdAt, modifiedAt: modifiedAt)
    }

    mutating func observe(_ row: Row) {
        if first {
            isSidechain = row["isSidechain"] as? Bool == true
            first = false
        }
        func field(_ name: String) -> String? {
            guard let value = row[name] as? String, !value.isEmpty else { return nil }
            return value
        }
        if cwd == nil { cwd = field("cwd") }
        if let value = field("gitBranch") { branch = value }
        if createdAt == nil { createdAt = transcriptDate(field("timestamp")) }
        if let value = field("customTitle") { custom = value }
        if let value = field("aiTitle") { generated = value }
        if let value = field("lastPrompt") { lastPrompt = value }
        if let value = field("summary") { summary = value }
        guard firstPrompt == nil, row["type"] as? String == "user", !Entry.isTaskNotification(row), row["isMeta"] as? Bool != true,
              row["isCompactSummary"] as? Bool != true, row["isSidechain"] as? Bool != true,
              let message = row["message"] as? Row else { return }
        let blocks = (message["content"] as? [Any] ?? []).compactMap { $0 as? Row }
        guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return }
        let texts = (message["content"] as? String).map { [$0] } ?? blocks.compactMap {
            $0["type"] as? String == "text" ? $0["text"] as? String : nil
        }
        for text in texts {
            let value = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if let start = value.range(of: "<command-name>"),
               let end = value.range(of: "</command-name>", range: start.upperBound..<value.endIndex) {
                if command == nil { command = String(value[start.upperBound..<end.lowerBound]) }
                continue
            }
            let skip = ["<local-command-stdout>", "<session-start-hook>", "<tick>", "<goal>", "[Request interrupted by user"]
            if skip.contains(where: value.hasPrefix) { continue }
            if ["ide_opened_file", "ide_selection"].contains(where: { value.hasPrefix("<\($0)>") && value.hasSuffix("</\($0)>") }) { continue }
            let prefix = value.prefix(200)
            firstPrompt = prefix.endIndex == value.endIndex ? value : String(prefix) + "…"
            return
        }
    }
}
