import Foundation

/// A scope recorded by a local top-level Codex thread. The project and date
/// describe the newest matching file and can be used to label an account picker.
public struct CodexLocalAccount: Sendable {
    public let accountID: String
    public let userID: String?
    public let lastWorkingDirectory: String?
    public let lastModified: Date
}

/// Reads locally persisted Codex sessions. Supplying an account scope selects matching marked rollouts.
public struct CodexReader: SessionReader {
    public let source = "codex"
    public let homeDirectory: URL
    public let includeArchived: Bool
    public let accountID: String?
    public let userID: String?
    private var snapshot: (files: [File], catalog: Catalog, names: [String: String])?

    /// Freeze file membership and indexed titles for one import pass. History is read on demand.
    public func catalogSnapshot() throws -> Self {
        let files = try files()
        var reader = self
        reader.snapshot = (files, Catalog(files), threadNames())
        return reader
    }

    public func scoped(accountID: String?, userID: String?) -> Self {
        var reader = Self(homeDirectory: homeDirectory, includeArchived: includeArchived, accountID: accountID, userID: userID)
        reader.snapshot = snapshot
        return reader
    }

    public init(homeDirectory: URL? = nil, includeArchived: Bool = false, accountID: String? = nil, userID: String? = nil) {
        let override = ProcessInfo.processInfo.environment["CODEX_HOME"]
        if let homeDirectory { self.homeDirectory = homeDirectory }
        else if let override, !override.isEmpty { self.homeDirectory = URL(fileURLWithPath: override, isDirectory: true) }
        else { self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }
        self.includeArchived = includeArchived
        self.accountID = accountID
        self.userID = userID
    }

    public func listSessions() throws -> [SessionInfo] {
        let names = snapshot?.names ?? threadNames()
        var sessions: [SessionInfo] = []
        let catalog = try snapshot?.catalog ?? Catalog(files())
        for value in catalog.sessions.keys {
            do {
                if let info = try read(value, catalog: catalog, name: names[value], history: false)?.info {
                    sessions.append(info)
                }
            } catch let error as CocoaError where error.isUnavailableFile { continue }
            catch SessionReadError.incompleteHistory { continue }
        }
        return sessions.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.id.value < $1.id.value
        }
    }

    public func readSession(_ id: SessionID) throws -> SessionHistory {
        guard id.source == source else { throw SessionReadError.unsupportedSource(id.source) }
        guard let uuid = UUID(uuidString: id.value) else { throw SessionReadError.invalidSessionID(id.value) }
        let value = uuid.uuidString.lowercased()
        let catalog = try snapshot?.catalog ?? Catalog(files())
        guard catalog.sessions[value] != nil else { throw SessionReadError.sessionNotFound(id) }
        let names = snapshot?.names ?? threadNames(matching: value)
        let name = names[value]
        guard let history = try read(value, catalog: catalog, name: name, history: true) else {
            throw SessionReadError.sessionNotFound(id)
        }
        return history
    }

    /// Discovers account identities from rollout headers without reading credentials.
    /// Discovery alone does not change which sessions this reader can open.
    public func localAccounts() throws -> [CodexLocalAccount] {
        var accounts: [CodexLocalAccount] = []
        // files() visits the most recently modified copy first.
        for file in try snapshot?.files ?? files() {
            try Task.checkCancellation()
            do {
                guard snapshot == nil || TranscriptFile.isRegularFile(file.url, under: homeDirectory),
                      let row = try TranscriptFile.firstRow(in: file.url), row["type"] as? String == "session_meta",
                      let header = row["payload"] as? Row, (header["id"] as? String)?.lowercased() == file.value,
                      Self.isUserThread(header), header["account_scoped"] as? Bool == true,
                      let account = header["creator_account_id"] as? String, !account.isEmpty else { continue }
                let owner = header["creator_user_id"]
                let user = owner as? String
                if let owner, !(owner is NSNull), user?.isEmpty != false { continue }
                if !accounts.contains(where: { $0.accountID == account && $0.userID == user }) {
                    accounts.append(.init(accountID: account, userID: user, lastWorkingDirectory: header["cwd"] as? String, lastModified: file.modified))
                }
            } catch let error as CocoaError where error.isUnavailableFile { continue }
        }
        // A user-scoped reader already includes the account's ownerless threads.
        let accountsWithUsers = Set(accounts.filter { $0.userID != nil }.map(\.accountID))
        return accounts.filter { $0.userID != nil || !accountsWithUsers.contains($0.accountID) }
    }

    private static func isUserThread(_ header: Row) -> Bool {
        if let source = header["thread_source"] as? String, source != "user" { return false }
        if header["source"] as? String == "subagent" { return false }
        if let source = header["source"] as? Row, source["subagent"] != nil { return false }
        if header["parent_thread_id"] is String && !(header["forked_from_id"] is String) { return false }
        return true
    }

    private func includes(_ header: Row) -> Bool {
        guard Self.isUserThread(header) else { return false }
        if let scope = header["account_scoped"] {
            guard let scoped = scope as? Bool else { return false }
            if !scoped { return true }
            guard let accountID, !accountID.isEmpty, header["creator_account_id"] as? String == accountID else { return false }
            if let owner = header["creator_user_id"], !(owner is NSNull) {
                guard let owner = owner as? String, !owner.isEmpty, owner == userID else { return false }
            }
        }
        return true
    }

    private enum Stop: Error { case finished }

    private struct Catalog {
        let sessions: [String: [String]]
        let segments: [String: [File]]

        init(_ files: [File]) {
            segments = Dictionary(grouping: files, by: \.segment)
            sessions = Dictionary(grouping: files, by: \.value).mapValues { copies in
                let root = copies[0].value
                let others = Set(copies.map(\.segment)).subtracting([root]).sorted()
                return copies.contains(where: { $0.segment == root }) ? [root] + others : others
            }
        }
    }

    private func read(_ value: String, catalog: Catalog, name: String?, history: Bool) throws -> SessionHistory? {
        guard let own = catalog.sessions[value], let headID = own.last else { return nil }
        let id = SessionID(source: source, value: value)
        var loaded: [String: CodexSegment] = [:]
        func load(_ key: String) throws -> CodexSegment? {
            if let segment = loaded[key] { return segment }
            var accessError: CocoaError?
            for file in catalog.segments[key] ?? [] {
                do {
                    guard snapshot == nil || TranscriptFile.isRegularFile(file.url, under: homeDirectory),
                          let row = try TranscriptFile.firstRow(in: file.url), row["type"] as? String == "session_meta",
                          let header = row["payload"] as? Row,
                          (header["id"] as? String)?.lowercased() == file.value, includes(header) else { continue }
                    let segment = try CodexSegment(key: key, file: file.url, modified: file.modified, header: header, id: id)
                    loaded[key] = segment
                    return segment
                } catch let error as CocoaError where error.isUnavailableFile {
                    if !error.isMissingFile { accessError = error }
                }
            }
            if let accessError { throw accessError }
            return nil
        }
        guard let head = try load(headID), head.threadID == value else { return nil }
        let original = headID == value ? head : try load(value)
        var title = name
        var transcript = CodexHistory()
        func result() -> SessionHistory {
            let info = SessionInfo(id: id, title: title ?? value, workingDirectory: head.cwd, gitBranch: head.branch,
                                   createdAt: original?.createdAt ?? head.createdAt, modifiedAt: head.modified)
            return transcript.finish(info: info)
        }
        if !history, title != nil { return result() }

        // A revert starts a new physical segment. A fork may reference a prefix in another thread.
        var ordered: [CodexSegment] = []
        var visited = Set<String>()
        var visiting = Set<String>()
        var cutoffs: [String: Set<Int>] = [:]
        func visit(_ segment: CodexSegment) throws {
            if visited.contains(segment.key) { return }
            guard visiting.insert(segment.key).inserted else { throw SessionReadError.incompleteHistory(id) }
            if let base = segment.base {
                guard let parent = try load(base.key) else { throw SessionReadError.incompleteHistory(id) }
                cutoffs[base.key, default: []].insert(base.end)
                try visit(parent)
            }
            visiting.remove(segment.key)
            visited.insert(segment.key)
            ordered.append(segment)
        }
        // Metadata needs only the retained lineage. History also includes abandoned records of this thread.
        do {
            if history {
                for key in own where key != headID {
                    if let segment = try load(key) { try visit(segment) }
                }
            }
            try visit(head)
        } catch SessionReadError.incompleteHistory where !history { return result() }

        let ownKeys = Set(own)
        var titleLimits = [head.key: Int.max]
        var ancestor = head
        while let base = ancestor.base, let parent = loaded[base.key] {
            titleLimits[parent.key] = base.end
            ancestor = parent
        }
        var checkpoints: [CodexSegment.Base: CodexHistory.Checkpoint] = [:]
        for segment in ordered {
            let limits = cutoffs[segment.key] ?? []
            let end = ownKeys.contains(segment.key) && history ? nil : limits.max()
            if let base = segment.base, history {
                guard let checkpoint = checkpoints[base] else { throw SessionReadError.incompleteHistory(id) }
                transcript.beginSegment(segment.key, at: checkpoint)
            } else { transcript.beginSegment(segment.key, at: .init()) }
            do {
                let nextOrdinal = try segment.readRows(before: end, id: id, includes: includes) { ordinal, row in
                    if limits.contains(ordinal), history {
                        checkpoints[.init(key: segment.key, end: ordinal)] = transcript.checkpoint()
                    }
                    if title == nil, let titleEnd = titleLimits[segment.key], ordinal < titleEnd,
                       let type = row["type"] as? String, let payload = row["payload"] as? Row,
                       let item = CodexItem.decode(type: type, payload: payload), item.role == .user,
                       let prompt = item.text?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !prompt.isEmpty {
                        title = String(prompt.prefix(200))
                        if !history { throw Stop.finished }
                    }
                    if history { transcript.observe(row) }
                }
                if history, limits.contains(nextOrdinal) {
                    checkpoints[.init(key: segment.key, end: nextOrdinal)] = transcript.checkpoint()
                }
            } catch Stop.finished {}
            if !history, title != nil { break }
        }
        return result()
    }

    private func threadNames(matching wanted: String? = nil) -> [String: String] {
        let index = homeDirectory.appendingPathComponent("session_index.jsonl")
        var names: [String: String] = [:]
        do {
            let values = try index.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return [:] }
            try TranscriptFile.forEachRow(in: index) { row in
                guard let id = (row["id"] as? String)?.lowercased(), wanted == nil || wanted == id,
                      let name = row["thread_name"] as? String else { return }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                names[id] = trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            // The index is an optional title hint. Discovery and direct reads use the rollouts.
        }
        return names
    }

    private struct File {
        let url: URL
        let value: String
        let segment: String
        let modified: Date
    }

    private func files() throws -> [File] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey]
        var result: [File] = []
        func visit(_ directory: URL, depth: Int) throws {
            let info = try directory.resourceValues(forKeys: keys)
            guard info.isDirectory == true, info.isSymbolicLink != true else { return }
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                        options: [.skipsHiddenFiles])
            for child in children {
                do {
                    if depth > 0 {
                        let name = child.lastPathComponent
                        guard name.utf8.count == (depth == 3 ? 4 : 2), name.utf8.allSatisfy({ (48...57).contains($0) }) else { continue }
                        try visit(child, depth: depth - 1)
                    } else {
                        let stem = child.deletingPathExtension().lastPathComponent
                        guard child.pathExtension == "jsonl", stem.hasPrefix("rollout-") else { continue }
                        let parts = stem.split(separator: "_", omittingEmptySubsequences: false)
                        guard parts.count <= 2, let first = parts.first, first.suffix(37).first == "-",
                              let uuid = UUID(uuidString: String(first.suffix(36))) else { continue }
                        let value = uuid.uuidString.lowercased()
                        let segment = parts.count == 2 ? UUID(uuidString: String(parts[1])) : uuid
                        guard let segment else { continue }
                        let info = try child.resourceValues(forKeys: keys)
                        guard info.isSymbolicLink != true, info.isRegularFile == true, let modified = info.contentModificationDate else { continue }
                        result.append(File(url: child, value: value, segment: segment.uuidString.lowercased(), modified: modified))
                    }
                } catch let error as CocoaError where error.isUnavailableFile { continue }
            }
        }
        do { try visit(homeDirectory.appendingPathComponent("sessions"), depth: 3) }
        catch let error as CocoaError where error.isMissingFile {}
        if includeArchived {
            do { try visit(homeDirectory.appendingPathComponent("archived_sessions"), depth: 0) }
            catch let error as CocoaError where error.isMissingFile {}
        }
        return result.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.url.path < $1.url.path
        }
    }
}
