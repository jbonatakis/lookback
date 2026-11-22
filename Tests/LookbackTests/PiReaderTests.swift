import Foundation
import Testing
import Lookback

private struct PiStore {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var reader: PiReader { PiReader(sessionsDirectory: root) }

    func write(_ text: String, to path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func fixture() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "pi-v3", withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@Test func piReplaysTheActiveBranchAndPreservesRecordedOccurrences() throws {
    let store = PiStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    #expect(try store.reader.listSessions().isEmpty)
    let fixture = try store.fixture()
    _ = try store.write(fixture + "\n" + #"{"type":"mess"#, to: "--lossy-dir--/unrelated-filename.jsonl")
    let reader = try store.reader.catalogSnapshot()
    let info = try #require(reader.listSessions().first)
    #expect(info.title == "Named session" && info.workingDirectory == "/work/pi-project" && info.gitBranch == nil)
    #expect(info.createdAt == Date(timeIntervalSince1970: 1767225600))
    let history = try reader.readSession(info.id)
    #expect(history.recordedMessages.map(\.id) == ["start", "abandoned", "branch", "ask", "call", "result", "compact", "reply"])
    #expect(history.transcript.map(\.id) == ["start", "branch", "ask", "call", "result", "compact", "reply"])
    #expect(history.conversation.map(\.id) == ["compact", "ask", "call", "reply"])
    #expect(history.conversation[0].isCompactionSummary)
    #expect(history.conversation[1].blocks == [.text("Updated for model")])
    #expect(history.transcript[2].blocks == [.other(type: "image"), .text("Inspect")])
    #expect(history.transcript[2].parentID == "branch")
    #expect(history.transcript[0].timestamp == Date(timeIntervalSince1970: 1))
    #expect(history.transcript[3].blocks == [.other(type: "thinking"), .toolCall(id: "t1", name: "read", inputJSON: Data(#"{"path":"example"}"#.utf8)), .other(type: "future_block")])
    #expect(history.transcript[4].blocks == [.toolResult(callID: "t1", contentJSON: Data(#"[{"text":"tool output","type":"text"}]"#.utf8), isError: true)])
    for message in history.conversation + history.transcript {
        let index = try #require(message.recordedIndex)
        #expect(history.recordedMessages[index].id == message.id)
    }
}

@Test func piCatalogUsesHeadersAndHandlesFlatStoresAndFileReplacement() throws {
    let store = PiStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let fixture = try store.fixture()
    let path = "flat.jsonl"
    let original = try store.write(fixture, to: path)
    _ = try store.write(fixture.replacingOccurrences(of: "/work/pi-project", with: "/work/another"), to: "another.jsonl")
    _ = try store.write(fixture.replacingOccurrences(of: #""version":3"#, with: #""version":1"#), to: "old.jsonl")
    try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("link.jsonl"), withDestinationURL: original)
    let snapshot = try store.reader.catalogSnapshot()
    let sessions = try snapshot.listSessions()
    #expect(sessions.count == 2 && Set(sessions.map(\.id)).count == 2)
    let id = try #require(sessions.first { $0.workingDirectory == "/work/pi-project" }?.id)
    let clear = #"{"type":"session_info","id":"clear","parentId":"name","name":""}"#
    _ = try store.write(fixture + "\n" + clear, to: path)
    #expect(try store.reader.listSessions().first { $0.id == id }?.title == "Original prompt")
    _ = try store.write(fixture.replacingOccurrences(of: "Review_1", with: "replacement"), to: path)
    #expect(throws: SessionReadError.sessionNotFound(id)) { try snapshot.readSession(id) }
    #expect(throws: SessionReadError.unsupportedSource("codex")) { try snapshot.readSession(.init(source: "codex", value: id.value)) }
}

@Test func piHandlesRetainNoneAndBrokenParentChains() throws {
    let store = PiStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let fixture = try store.fixture()
    let compact = #"{"type":"compaction","id":"new","parentId":"name","firstKeptEntryId":"new","summary":"New checkpoint"}"#
    _ = try store.write(fixture + "\n" + compact, to: "flat.jsonl")
    let reader = store.reader
    let id = try #require(reader.listSessions().first?.id)
    #expect(try reader.readSession(id).conversation.map(\.id) == ["new"])
    _ = try store.write(fixture + "\n" + compact.replacingOccurrences(of: #""parentId":"name""#, with: #""parentId":"new""#), to: "flat.jsonl")
    #expect(throws: SessionReadError.incompleteHistory(id)) { try reader.readSession(id) }
}
