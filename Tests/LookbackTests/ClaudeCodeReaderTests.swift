import Foundation
import Testing
import Lookback

private let primary = "be0e3ab5-aa10-4044-8fdc-79782a70d7ae"
private let secondary = "00000000-0000-4000-a000-000000000001"
private let sid = SessionID(source: "claude-code", value: primary)

private struct Store {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var reader: ClaudeCodeReader { ClaudeCodeReader(projectsDirectory: root) }

    @discardableResult
    func write(_ text: String, _ filename: String = primary, in project: String = "project") throws -> URL {
        let directory = root.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename + ".jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

@Test func taskNotificationOriginDistinguishesAgentOutputFromPastedText() throws {
    let store = Store()
    defer { store.cleanUp() }
    let text = "<task-notification><task-id>agent-1</task-id><tool-use-id>call-2</tool-use-id><status>completed</status><summary>Review finished</summary><result>a < b && c; quoted <status>failed</status></result></task-notification>"
    let rows: [[String: Any]] = [
        ["uuid": "paste", "type": "user", "message": ["content": text]],
        ["uuid": "event", "parentUuid": "paste", "type": "user", "origin": ["kind": "task-notification"], "message": ["content": text]],
        ["uuid": "invalid", "parentUuid": "event", "type": "user", "turnOrigin": "task_notification",
         "message": ["content": [["type": "text", "text": "partial payload"]]]]
    ]
    try store.write(try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n"))
    let history = try store.reader.readSession(sid)
    for messages in [history.conversation, history.transcript, history.recordedMessages] {
        #expect(messages.map(\.id) == ["paste", "event", "invalid"])
        #expect(messages[0].taskNotification == nil && messages[0].blocks == [.text(text)])
        #expect(messages[1].taskNotification == .init(taskID: "agent-1", toolUseID: "call-2", status: "completed",
                                                      summary: "Review finished", result: "a < b && c; quoted <status>failed</status>"))
        #expect(messages[1].blocks == [.text(text)])
        #expect(messages[2].taskNotification == SessionTaskNotification() && messages[2].blocks == [.text("partial payload")])
    }
}

@Test func discoveryAndReadUseTheSameNewestCopy() throws {
    let store = Store()
    defer { store.cleanUp() }
    let old = try store.write(#"{"uuid":"old","type":"user","message":{"content":"old prompt"}}"#, in: "other")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 50)], ofItemAtPath: old.path)
    try store.write(#"""
    {"type":"user","uuid":"prompt","cwd":"/a-real/project","gitBranch":"first","timestamp":"2026-01-02T03:04:05.123Z","message":{"content":[{"type":"text","text":"find that bug"}]}}
    {"type":"custom-title","customTitle":"My investigation"}
    {"type":"ai-title","aiTitle":"Alternative"}
    {"type":"assistant","uuid":"reply","parentUuid":"prompt","gitBranch":"fix","message":{"content":[{"type":"future-type","field":7}]}}
    {"type":"assistant","uuid":
    """#, primary.uppercased())
    try store.write(#"{"uuid":"worker","type":"user","message":{"content":"nested"}}"#, secondary, in: "project/session/subagents")
    try store.write(#"{"uuid":"aside","type":"user","isSidechain":true,"message":{"content":"subagent"}}"#, secondary, in: "side")
    try store.write(#"{"type":"last-prompt","lastPrompt":"wrong"}"#, "not-a-session")
    let sessions = try store.reader.listSessions()
    #expect(sessions.map(\.id) == [sid])
    let info = try #require(sessions.first)
    #expect(info.title == "My investigation" && info.workingDirectory == "/a-real/project")
    #expect(info.gitBranch == "fix" && info.createdAt != nil)
    let history = try store.reader.readSession(info.id)
    #expect(history.info?.id == info.id && history.info?.title == info.title)
    #expect(history.info?.workingDirectory == info.workingDirectory && history.info?.gitBranch == info.gitBranch)
    #expect(history.conversation.map(\.id) == ["prompt", "reply"])
    #expect(history.conversation.last?.blocks == [.other(type: "future-type")])
}

@Test(.enabled(if: geteuid() != 0)) func unreadableTranscriptsAndProjectsDoNotHideReadableSessions() throws {
    let store = Store()
    defer { store.cleanUp() }
    let prompt = #"{"uuid":"u","type":"user","message":{"content":"readable"}}"#
    let readable = try store.write(prompt)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 50)], ofItemAtPath: readable.path)
    let newerCopy = try store.write(prompt, in: "copy")
    let unreadable = try store.write(prompt, secondary)
    let project = try store.write(prompt, in: "restricted").deletingLastPathComponent()
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path) }
    for url in [newerCopy, unreadable, project] {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    }

    let sessions = try store.reader.listSessions()
    #expect(sessions.map(\.id) == [sid])
    #expect(sessions.first?.modifiedAt == Date(timeIntervalSince1970: 50))
    #expect(try store.reader.readSession(sid).conversation.first?.blocks == [.text("readable")])
    let inaccessibleID = SessionID(source: sid.source, value: secondary)
    #expect(throws: CocoaError.self) { try store.reader.readSession(inaccessibleID) }
}

@Test func compactionAndBranchesHaveTwoDistinctViews() throws {
    let store = Store()
    defer { store.cleanUp() }
    try store.write(#"""
    {"type":"user","uuid":"original","message":{"content":"initial prompt"}}
    {"type":"assistant","uuid":"old","parentUuid":"original","message":{"content":"earlier work"}}
    {"type":"system","uuid":"boundary","logicalParentUuid":"old"}
    {"type":"user","uuid":"summary","parentUuid":"boundary","isCompactSummary":true,"message":{"content":"earlier context"}}
    {"type":"assistant","uuid":"discarded","parentUuid":"summary","message":{"content":"old branch"}}
    {"type":"assistant","uuid":"current","parentUuid":"summary","message":{"content":"current branch"}}
    {"type":"progress","uuid":"progress","parentUuid":"current"}
    {"type":"user","uuid":"metadata","parentUuid":"discarded","isMeta":true,"message":{"content":"hidden"}}
    {"type":"user","uuid":"team","teamName":"red","message":{"content":"hidden"}}
    """#)
    let history = try store.reader.readSession(sid)
    #expect(history.conversation.map(\.id) == ["summary", "current"])
    #expect(history.conversation.first?.role == .system && history.conversation.first?.isCompactionSummary == true)
    #expect(history.recordedMessages.map(\.id) == ["original", "old", "summary", "discarded", "current"])
}

@Test func parallelToolResultsStayWithTheirResponse() throws {
    let store = Store()
    defer { store.cleanUp() }
    try store.write(#"""
    {"type":"user","uuid":"u","message":{"content":"look both up"}}
    {"type":"assistant","uuid":"a","parentUuid":"u","message":{"id":"resp","content":[{"type":"tool_use","id":"one","name":"lookup","input":{"key":1}}]}}
    {"type":"assistant","uuid":"b","parentUuid":"a","message":{"id":"resp","content":[{"type":"tool_use","id":"two","name":"lookup","input":{}}]}}
    {"type":"user","uuid":"r1","parentUuid":"a","message":{"content":[{"type":"tool_result","tool_use_id":"one","content":"OK"}]}}
    {"type":"user","uuid":"wrongwriter","parentUuid":"external","agentId":"someone-else","sourceToolAssistantUUID":"b","message":{"content":[{"type":"tool_result","tool_use_id":"two"}]}}
    {"type":"user","uuid":"r2","parentUuid":"external","sourceToolAssistantUUID":"b","message":{"content":[{"type":"tool_result","tool_use_id":"two","is_error":true,"content":"Failed"}]}}
    {"type":"user","uuid":"repeat","parentUuid":"external","message":{"content":[{"type":"tool_result","tool_use_id":"two"}]}}
    {"type":"assistant","uuid":"done","parentUuid":"r1","message":{"id":"next","content":"done"}}
    """#)
    let messages = try store.reader.readSession(sid).conversation
    #expect(messages.map(\.id) == ["u", "a", "b", "r2", "r1", "done"])
    #expect(messages.compactMap(\.recordedIndex) == [0, 1, 2, 5, 3, 7])
    #expect(messages[1].blocks == [.toolCall(id: "one", name: "lookup", inputJSON: Data(#"{"key":1}"#.utf8))])
    #expect(messages[3].role == .tool)
    #expect(messages[3].blocks == [.toolResult(callID: "two", contentJSON: Data(#""Failed""#.utf8), isError: true)])
}

@Test func noCrossResponseGuessForReusedCallID() throws {
    let store = Store()
    defer { store.cleanUp() }
    try store.write(#"""
    {"type":"assistant","uuid":"a","message":{"id":"first","content":[{"type":"tool_use","id":"dup","name":"run"}]}}
    {"type":"assistant","uuid":"b","message":{"id":"other","content":[{"type":"tool_use","id":"dup","name":"run"}]}}
    {"type":"user","uuid":"stray","parentUuid":"missing","message":{"content":[{"type":"tool_result","tool_use_id":"dup"}]}}
    {"type":"user","uuid":"end","parentUuid":"a","message":{"content":"next"}}
    """#)
    #expect(try store.reader.readSession(sid).conversation.map(\.id) == ["a", "end"])
}

@Test func readRejectsWrongProviderAndPathsAndHandlesMissingStore() throws {
    let reader: any SessionReader = Store().reader
    #expect(try reader.listSessions().isEmpty)
    #expect(throws: SessionReadError.unsupportedSource("other")) {
        try reader.readSession(SessionID(source: "other", value: primary))
    }
    #expect(throws: SessionReadError.invalidSessionID("../escape")) {
        try reader.readSession(SessionID(source: reader.source, value: "../escape"))
    }
    #expect(throws: SessionReadError.sessionNotFound(sid)) { try reader.readSession(sid) }
}

@Test func longAndPartiallyWrittenRows() throws {
    let store = Store()
    defer { store.cleanUp() }
    let longText = String(repeating: "🪶", count: 90_000)
    let line = #"{"type":"user","uuid":"large","message":{"content":"\#(longText)"}}"#
    let file = try store.write(line + "\n" + #"{"type":"assistant","uuid":"new","#)
    let firstList = try store.reader.listSessions()
    #expect(firstList.first?.title == String(longText.prefix(200)) + "…")
    #expect(try store.reader.readSession(sid).conversation.map(\.id) == ["large"])
    let output = try FileHandle(forWritingTo: file)
    try output.seekToEnd()
    try output.write(contentsOf: Data(#""parentUuid":"large","message":{"content":"done"}}"#.utf8))
    try output.close()
    #expect(try store.reader.readSession(sid).conversation.map(\.id) == ["large", "new"])
}

@Test func cyclicParentsAndMissingParentAreBounded() throws {
    let store = Store()
    defer { store.cleanUp() }
    try store.write(#"""
    {"type":"user","uuid":"a","parentUuid":"b","message":{"content":"earlier"}}
    {"type":"user","uuid":"b","parentUuid":"a","message":{"content":"cycle"}}
    {"type":"user","uuid":"c","parentUuid":"lost","message":{"content":"isolated"}}
    """#)
    #expect(try store.reader.readSession(sid).conversation.map(\.id) == ["c"])
}

@Test func extraContentAndDuplicateLeafIDsPreserveTheOriginalBranchChoice() throws {
    let store = Store()
    defer { store.cleanUp() }
    try store.write(#"""
    {"type":"user","uuid":"first","message":{"content":[null,{"type":"text","text":"first prompt"}]}}
    {"type":"progress","uuid":"internal","parentUuid":"first"}
    {"type":"user","uuid":"second","message":{"content":"alternative"}}
    {"type":"assistant","uuid":"same","parentUuid":"first","message":{"content":[7,{"type":"text","text":"first terminal"}]}}
    {"type":"assistant","uuid":"same","parentUuid":"second","message":{"content":"second terminal"}}
    """#)
    let history = try store.reader.readSession(sid)
    let recorded = history.recordedMessages
    try #require(recorded.map(\.id) == ["first", "second", "same", "same"])
    #expect(recorded.compactMap(\.recordedIndex) == [0, 1, 2, 3])
    #expect(recorded[2].blocks == [.text("first terminal")])
    #expect(recorded[3].blocks == [.text("second terminal")])
    let messages = history.conversation
    #expect(messages.map(\.id) == ["first", "same"])
    #expect(messages.compactMap(\.recordedIndex) == [0, 2])
    #expect(messages.first?.blocks == [.text("first prompt")])
    #expect(messages.last?.blocks == [.text("first terminal")])
}

@Test func symbolicLinksAreNotDiscoveredAsSessionFilesOrProjectDirectories() throws {
    let store = Store()
    let outside = Store()
    defer { store.cleanUp(); outside.cleanUp() }
    let row = #"{"type":"user","uuid":"u","message":{"content":"hello"}}"#
    let real = try store.write(row)
    let external = try outside.write(row, secondary)
    let fakeSession = real.deletingLastPathComponent().appendingPathComponent(secondary + ".jsonl")
    try FileManager.default.createSymbolicLink(at: fakeSession, withDestinationURL: external)
    try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("linked"),
                                               withDestinationURL: external.deletingLastPathComponent())
    #expect(try store.reader.listSessions().map(\.id) == [sid])
    let absent = SessionID(source: store.reader.source, value: secondary)
    #expect(throws: SessionReadError.sessionNotFound(absent)) { try store.reader.readSession(absent) }
}

@Test func claudeCatalogSkipsReplacedLinksAndDiscoversNewFilesOnTheNextPass() throws {
    let store = Store()
    defer { store.cleanUp() }
    let content = #"{"uuid":"hi","type":"user","message":{"content":"hello"}}"#
    let original = try store.write(content)
    let snapshot = try store.reader.catalogSnapshot()
    let other = try store.write(content, secondary)
    #expect(try snapshot.listSessions().map(\.id) == [sid])
    #expect(try snapshot.readSession(sid).conversation.count == 1)
    try FileManager.default.removeItem(at: original)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: other)
    #expect(try snapshot.listSessions().isEmpty)
    #expect(throws: SessionReadError.self) { try snapshot.readSession(sid) }
    #expect(try snapshot.catalogSnapshot().listSessions().count == 1)
}
