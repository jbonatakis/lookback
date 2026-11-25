import Foundation
import SQLite3

/// Reads the Antigravity CLI catalog and its generated, user-visible transcript steps.
public struct AntigravityReader: SessionReader {
    public let source = "antigravity"
    private let directory: URL
    private var catalog: [SessionID: SessionInfo]?

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli")) {
        self.directory = directory
    }

    public func catalogSnapshot() throws -> Self {
        var copy = self
        copy.catalog = try sessions()
        return copy
    }

    private func transcript(_ id: SessionID) -> URL {
        directory.appendingPathComponent("brain/\(id.value)/.system_generated/logs/transcript_full.jsonl")
    }

    private func sessions() throws -> [SessionID: SessionInfo] {
        if let catalog { return catalog }
        let path = directory.appendingPathComponent("conversation_summaries.db").path
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        do {
            return try readCatalog(path)
        } catch let error as NSError where error.domain == "AntigravityCatalog" && error.code == Int(SQLITE_CANTOPEN) {
            // A checkpointed WAL database can require SQLite to create sidecars even for a
            // read-only query. Open a private copy only when all committed data is in the main file.
            let fm = FileManager.default
            let main = URL(fileURLWithPath: path)
            func hasJournal() -> Bool {
                ["-wal", "-journal"].contains { fm.fileExists(atPath: path + $0) }
            }
            guard !hasJournal() else { throw error }
            let before = try fm.attributesOfItem(atPath: path)
            let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: folder) }
            let copy = folder.appendingPathComponent(main.lastPathComponent)
            try fm.copyItem(at: main, to: copy)
            let after = try fm.attributesOfItem(atPath: path)
            guard !hasJournal(), [.systemFileNumber, .size, .modificationDate].allSatisfy({ key in
                (before[key] as? NSObject)?.isEqual(after[key]) == true
            }) else { throw error }
            return try readCatalog(copy.path, writableCopy: true)
        }
    }

    private func readCatalog(_ path: String, writableCopy: Bool = false) throws -> [SessionID: SessionInfo] {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(path, &db, writableCopy ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        func failure() -> NSError {
            NSError(domain: "AntigravityCatalog", code: Int(sqlite3_errcode(db)),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
        guard opened == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(db, 500)
        let query = """
            SELECT conversation_id, title, workspace_uris,
                   (julianday(last_modified_time) - 2440587.5) * 86400
            FROM conversation_summaries
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        func string(_ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }
        var result: [SessionID: SessionInfo] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let id = SessionID(source: source, value: string(0))
            if UUID(uuidString: id.value) != nil,
               let uris = try? JSONDecoder().decode([String].self, from: Data(string(2).utf8)),
               let workspace = uris.compactMap({ URL(string: $0) }).first(where: { $0.isFileURL }),
               let attributes = try? transcript(id).resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = attributes.contentModificationDate {
                let title = string(1)
                result[id] = SessionInfo(id: id, title: title.isEmpty ? "Antigravity session" : title,
                                         workingDirectory: workspace.path, gitBranch: nil, createdAt: nil,
                                         modifiedAt: max(modified, Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))))
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    public func listSessions() throws -> [SessionInfo] {
        try sessions().values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func readSession(_ id: SessionID) throws -> SessionHistory {
        guard id.source == source else { throw SessionReadError.unsupportedSource(id.source) }
        guard UUID(uuidString: id.value) != nil else { throw SessionReadError.invalidSessionID(id.value) }
        guard let info = try sessions()[id] else { throw SessionReadError.sessionNotFound(id) }
        let data = try Data(contentsOf: transcript(id), options: .mappedIfSafe)
        let decoder = JSONDecoder()
        let dates = ISO8601DateFormatter()
        let fractionalDates = ISO8601DateFormatter()
        fractionalDates.formatOptions.insert(.withFractionalSeconds)
        var steps: [Int: Step] = [:]
        for line in data.split(separator: 10) {
            guard let step = try? decoder.decode(Step.self, from: line),
                  step.type == "USER_INPUT" || step.type == "PLANNER_RESPONSE" else { continue }
            steps[step.step_index] = step
        }
        var messages: [SessionMessage] = []
        for index in steps.keys.sorted() {
            guard let step = steps[index] else { continue }
            let isUser = step.type == "USER_INPUT"
            var blocks: [MessageBlock] = []
            if var text = step.content {
                if isUser && text.hasPrefix("<USER_REQUEST>") {
                    guard let end = text.range(of: "</USER_REQUEST>", options: .backwards) else { continue }
                    text = String(text[text.index(text.startIndex, offsetBy: "<USER_REQUEST>".count)..<end.lowerBound])
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { blocks.append(.text(text)) }
            }
            for (offset, call) in (step.tool_calls ?? []).enumerated() {
                blocks.append(.toolCall(id: "\(index)-\(offset)", name: call.name, inputJSON: nil))
            }
            guard !blocks.isEmpty else { continue }
            let timestamp = step.created_at.flatMap { dates.date(from: $0) ?? fractionalDates.date(from: $0) }
            messages.append(SessionMessage(id: "step-\(index)", parentID: messages.last?.id,
                                           timestamp: timestamp, role: isUser ? .user : .assistant,
                                           blocks: blocks, recordedIndex: messages.count))
        }
        return SessionHistory(id: id, conversation: messages, recordedMessages: messages, info: info)
    }

    private struct Step: Decodable {
        struct Call: Decodable { let name: String }
        let step_index: Int
        let type: String
        let created_at: String?
        let content: String?
        let tool_calls: [Call]?
    }
}
