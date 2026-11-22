import Foundation

/// Reads persisted Pi v3 sessions. A snapshot shares a catalog between listing and individual reads.
public struct PiReader: SessionReader {
    public let source = "pi"
    public let sessionsDirectory: URL
    private var snapshot: Catalog?

    public init(sessionsDirectory: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        func directory(_ key: String) -> URL? {
            guard let path = environment[key], !path.isEmpty else { return nil }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let agent = directory("PI_CODING_AGENT_DIR") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent")
        self.sessionsDirectory = sessionsDirectory ?? directory("PI_CODING_AGENT_SESSION_DIR") ?? agent.appendingPathComponent("sessions")
    }

    public func catalogSnapshot() throws -> Self {
        var reader = self
        reader.snapshot = try catalog()
        return reader
    }

    public func listSessions() throws -> [SessionInfo] {
        let catalog = try snapshot ?? catalog()
        return catalog.sessions
    }

    public func readSession(_ id: SessionID) throws -> SessionHistory {
        guard id.source == source else { throw SessionReadError.unsupportedSource(id.source) }
        let parts = id.value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, PiMetadata.validID(String(parts[0])), !parts[1].isEmpty else {
            throw SessionReadError.invalidSessionID(id.value)
        }
        let catalog = try snapshot ?? catalog()
        for file in catalog.byID[id] ?? [] where TranscriptFile.isRegularFile(file.url, under: sessionsDirectory) {
            do {
                var metadata = PiMetadata()
                var history = PiHistory()
                try TranscriptFile.forEachRow(in: file.url) { row in
                    try Task.checkCancellation()
                    metadata.observe(row)
                    guard metadata.id == id else { throw SessionReadError.sessionNotFound(id) }
                    history.append(row)
                }
                if let info = metadata.info(modified: file.info.modifiedAt) {
                    return try history.finish(info: info)
                }
            } catch let error as CocoaError where error.isUnavailableFile {
                continue
            } catch SessionReadError.sessionNotFound {
                continue // Replaced after discovery.
            }
        }
        throw SessionReadError.sessionNotFound(id)
    }

    private struct File: Sendable {
        let url: URL
        let info: SessionInfo
    }

    private struct Catalog: Sendable {
        let sessions: [SessionInfo]
        let byID: [SessionID: [File]]
    }

    private func catalog() throws -> Catalog {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        func children(_ directory: URL) throws -> [URL] {
            do {
                return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                                   options: [.skipsHiddenFiles])
            } catch let error as CocoaError where error.isMissingFile { return [] }
        }
        var files: [File] = []
        func collect(_ url: URL) throws {
            try Task.checkCancellation()
            guard url.pathExtension == "jsonl", TranscriptFile.isRegularFile(url, under: sessionsDirectory) else { return }
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard let modified = values.contentModificationDate, let size = values.fileSize else { return }
                if let info = try PiMetadataCache.shared.info(at: url, modified: modified, size: size) {
                    files.append(File(url: url, info: info))
                }
            } catch let error as CocoaError where error.isUnavailableFile {}
        }
        for url in try children(sessionsDirectory) {
            try Task.checkCancellation()
            let name = url.lastPathComponent
            if name.hasPrefix("--"), name.hasSuffix("--") {
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    for child in try children(url) { try collect(child) }
                } catch let error as CocoaError where error.isUnavailableFile {}
            } else {
                try collect(url) // Pi writes directly into a custom session directory.
            }
        }
        files.sort {
            if $0.info.modifiedAt != $1.info.modifiedAt { return $0.info.modifiedAt > $1.info.modifiedAt }
            return $0.url.path < $1.url.path
        }
        var seen = Set<SessionID>()
        let sessions = files.compactMap { seen.insert($0.info.id).inserted ? $0.info : nil }
        return Catalog(sessions: sessions, byID: Dictionary(grouping: files, by: { $0.info.id }))
    }
}

private struct PiMetadata {
    private var first = true
    private var nativeID: String?
    private var cwd: String?
    private var created: Date?
    private var name: String?
    private var prompt: String?
    private(set) var id: SessionID?

    static func validID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z"#, options: .regularExpression) != nil
    }

    mutating func observe(_ row: Row) {
        if first {
            first = false
            guard row["type"] as? String == "session", row["version"] as? Int == 3,
                  let native = row["id"] as? String, Self.validID(native),
                  let path = row["cwd"] as? String, !path.isEmpty else { return }
            nativeID = native
            cwd = path
            id = SessionID(source: "pi", value: native + "@" + path)
            created = transcriptDate(row["timestamp"] as? String)
            return
        }
        guard id != nil else { return }
        if row["type"] as? String == "session_info" {
            let value = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            name = value?.isEmpty == false ? value : nil
        } else if prompt == nil, row["type"] as? String == "message", let message = row["message"] as? Row,
                  message["role"] as? String == "user" {
            for case .text(let text) in PiHistory.blocks(message["content"]) {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                prompt = String(value.prefix(200)).replacingOccurrences(of: "\n", with: " ")
                break
            }
        }
    }

    func info(modified: Date) -> SessionInfo? {
        guard let id, let nativeID else { return nil }
        return SessionInfo(id: id, title: name ?? prompt ?? nativeID, workingDirectory: cwd, gitBranch: nil,
                           createdAt: created, modifiedAt: modified)
    }
}

// A rename can occur anywhere in the log. Cache only catalog metadata so periodic discovery doesn't
// reread every unchanged transcript to find its latest name. NSCache supports concurrent readers.
private final class PiMetadataCache: @unchecked Sendable {
    static let shared = PiMetadataCache()
    private final class Value {
        let modified: Date, size: Int, info: SessionInfo?
        init(_ modified: Date, _ size: Int, _ info: SessionInfo?) {
            self.modified = modified; self.size = size; self.info = info
        }
    }
    private let cache = NSCache<NSURL, Value>()
    private init() { cache.countLimit = 4096 }

    func info(at url: URL, modified: Date, size: Int) throws -> SessionInfo? {
        if let value = cache.object(forKey: url as NSURL), value.modified == modified, value.size == size { return value.info }
        var metadata = PiMetadata()
        try TranscriptFile.forEachRow(in: url) { row in
            try Task.checkCancellation()
            metadata.observe(row)
        }
        let info = metadata.info(modified: modified)
        cache.setObject(Value(modified, size, info), forKey: url as NSURL)
        return info
    }
}
