import Foundation

/// Reads the local Claude Code projects store. All operations are synchronous and read-only.
public struct ClaudeCodeReader: SessionReader {
    public let source = "claude-code"
    public let projectsDirectory: URL

    /// Uses CLAUDE_CONFIG_DIR/projects or ~/.claude/projects unless given a projects directory directly.
    public init(projectsDirectory: URL? = nil) {
        let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let config: URL
        if let override, !override.isEmpty { config = URL(fileURLWithPath: override, isDirectory: true) }
        else { config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude") }
        self.projectsDirectory = projectsDirectory ?? config.appendingPathComponent("projects")
    }

    public func listSessions() throws -> [SessionInfo] {
        var sessions: [SessionInfo] = []
        var visited = Set<String>()
        for file in try files() where !visited.contains(file.value) {
            do {
                var metadata = SessionMetadata()
                let complete = try TranscriptFile.sample(in: file.url) { metadata.observe($0) }
                if !complete, !metadata.isSidechain, metadata.title == nil {
                    metadata = SessionMetadata()
                    try TranscriptFile.forEachRow(in: file.url) { metadata.observe($0) }
                }
                visited.insert(file.value)
                if let info = metadata.info(id: SessionID(source: source, value: file.value), modifiedAt: file.modified) {
                    sessions.append(info)
                }
            } catch let error as CocoaError where Self.isUnavailable(error) {
                continue
            }
        }
        return sessions
    }

    public func readSession(_ id: SessionID) throws -> SessionHistory {
        guard id.source == source else { throw SessionReadError.unsupportedSource(id.source) }
        guard let uuid = UUID(uuidString: id.value) else { throw SessionReadError.invalidSessionID(id.value) }
        let value = uuid.uuidString.lowercased()
        let canonicalID = SessionID(source: source, value: value)
        var accessError: CocoaError?
        for file in try files(matching: value) {
            var rows: [Entry] = []
            var metadata = SessionMetadata()
            do {
                try TranscriptFile.forEachRow(in: file.url) {
                    metadata.observe($0)
                    if let entry = Entry($0) { rows.append(entry) }
                }
                return SessionHistory(id: canonicalID, conversation: Conversation(rows).messages(),
                                      recordedMessages: rows.compactMap(\.message),
                                      info: metadata.info(id: canonicalID, modifiedAt: file.modified))
            } catch let error as CocoaError where Self.isUnavailable(error) {
                if !Self.isMissing(error) { accessError = error }
            }
        }
        if let accessError { throw accessError }
        throw SessionReadError.sessionNotFound(id)
    }

    private struct SessionFile {
        let value: String
        let url: URL
        let modified: Date
    }

    private static func isMissing(_ error: CocoaError) -> Bool {
        error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    }

    private static func isUnavailable(_ error: CocoaError) -> Bool {
        // FileHandle can report fileWriteNoPermission even when opening a file for reading.
        isMissing(error) || error.code == .fileReadNoPermission || error.code == .fileWriteNoPermission
    }

    private func children(of directory: URL, keys: Set<URLResourceKey>) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                               options: [.skipsHiddenFiles])
        } catch let error as CocoaError where Self.isMissing(error) {
            return []
        }
    }

    private func files(matching wanted: String? = nil) throws -> [SessionFile] {
        var result: [SessionFile] = []
        let directories: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        for project in try children(of: projectsDirectory, keys: directories) {
            do {
                let directory = try project.resourceValues(forKeys: directories)
                guard directory.isDirectory == true, directory.isSymbolicLink != true else { continue }
                for file in try children(of: project, keys: keys) where file.pathExtension == "jsonl" {
                    guard let uuid = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
                    let value = uuid.uuidString.lowercased()
                    guard wanted == nil || wanted == value else { continue }
                    let attributes: URLResourceValues
                    do { attributes = try file.resourceValues(forKeys: keys) }
                    catch let error as CocoaError where Self.isUnavailable(error) { continue }
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                          let modified = attributes.contentModificationDate else { continue }
                    result.append(SessionFile(value: value, url: file, modified: modified))
                }
            } catch let error as CocoaError where Self.isUnavailable(error) {
                continue
            }
        }
        return result.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.url.path < $1.url.path
        }
    }
}
