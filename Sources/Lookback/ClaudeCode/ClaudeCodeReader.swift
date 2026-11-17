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
        for (value, file) in try files() {
            do {
                var metadata = SessionMetadata()
                let complete = try TranscriptFile.sample(in: file.url) { metadata.observe($0) }
                if !complete, !metadata.isSidechain, metadata.title == nil {
                    metadata = SessionMetadata()
                    try TranscriptFile.forEachRow(in: file.url) { metadata.observe($0) }
                }
                guard !metadata.isSidechain, let title = metadata.title else { continue }
                sessions.append(SessionInfo(
                    id: SessionID(source: source, value: value), title: title,
                    workingDirectory: metadata.cwd, gitBranch: metadata.branch,
                    createdAt: metadata.createdAt, modifiedAt: file.modified
                ))
            } catch let error as CocoaError where Self.isMissing(error) {
                continue // Claude Code can move or delete a session during discovery.
            }
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
        guard let file = try files(matching: value)[value] else { throw SessionReadError.sessionNotFound(id) }
        var rows: [Entry] = []
        do {
            try TranscriptFile.forEachRow(in: file.url) {
                if let entry = Entry($0) { rows.append(entry) }
            }
        } catch let error as CocoaError where Self.isMissing(error) {
            throw SessionReadError.sessionNotFound(id)
        }
        return SessionHistory(id: SessionID(source: source, value: value), conversation: Conversation(rows).messages(),
                              recordedMessages: rows.compactMap(\.message))
    }

    private struct SessionFile {
        let url: URL
        let modified: Date
    }

    private static func isMissing(_ error: CocoaError) -> Bool {
        error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    }

    private func children(of directory: URL, keys: Set<URLResourceKey>) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                               options: [.skipsHiddenFiles])
        } catch let error as CocoaError where Self.isMissing(error) {
            return []
        }
    }

    private func files(matching wanted: String? = nil) throws -> [String: SessionFile] {
        var result: [String: SessionFile] = [:]
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
                    catch let error as CocoaError where Self.isMissing(error) { continue }
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                          let modified = attributes.contentModificationDate else { continue }
                    if let previous = result[value],
                       previous.modified > modified || (previous.modified == modified && previous.url.path <= file.path) { continue }
                    result[value] = SessionFile(url: file, modified: modified)
                }
            } catch let error as CocoaError where Self.isMissing(error) {
                continue
            }
        }
        return result
    }
}
