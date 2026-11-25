import Foundation
import Testing
import Lookback

private let legacyID = "019a1234-5678-7000-8000-000000000001"
private let paginatedID = "019a1234-5678-7000-8000-000000000002"

private struct CodexStore {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var reader: CodexReader { CodexReader(homeDirectory: home) }

    func fixture(_ name: String) throws -> String {
        let file = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: file, encoding: .utf8)
    }

    @discardableResult
    func write(_ text: String, id: String = legacyID, directory: String = "sessions/2026/01/02") throws -> URL {
        let parent = home.appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent("rollout-2026-01-02T12-00-00-\(id).jsonl")
        try Data(text.utf8).write(to: file)
        return file
    }

    func cleanUp() { try? FileManager.default.removeItem(at: home) }
}

@Test(arguments: ["legacy", "paginated"])
func codexProjectsBothHistoryViews(_ mode: String) throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    let modern = mode == "paginated"
    let id = modern ? paginatedID : legacyID
    try store.write(store.fixture(mode), id: id)
    let history = try store.reader.readSession(SessionID(source: "codex", value: id.uppercased()))
    #expect(history.info?.title == "Again")
    #expect(history.info?.workingDirectory == "/sample" && history.info?.gitBranch == "main")
    let expected: [[MessageBlock]] = [
        [.text("Again")], [.toolCall(id: "c1", name: "lookup", inputJSON: Data(#"{"key":1}"#.utf8))],
        [.toolResult(callID: "c1", contentJSON: Data(#""found""#.utf8), isError: false)],
        [.text("Answer 1")], [.text("Again")], [.text("Answer 2")]
    ]
    #expect(history.recordedMessages.map(\.blocks) == expected + (modern ? [[.other(type: "compaction")]] : []))
    #expect(history.recordedMessages.compactMap(\.recordedIndex) == Array(history.recordedMessages.indices))
    #expect(history.conversation.compactMap(\.recordedIndex) == (modern ? [4, 6] : [0, 1, 2, 3]))
    #expect(history.transcript.compactMap(\.recordedIndex) == Array(0..<(modern ? 6 : 4)))
    if modern {
        #expect(history.conversation.map(\.id) == ["ui-2", "compact-1"])
        #expect(history.conversation.last?.isCompactionSummary == true)
    }
}

@Test func codexTranscriptSurvivesCompactionAndDropsRolledBackReplies() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    let fixture = try store.fixture("paginated")
    let continuation = """
    {"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}
    {"type":"event_msg","payload":{"type":"user_message","message":"Try again"}}
    {"type":"event_msg","payload":{"type":"agent_message","message":"Revised answer"}}
    {"type":"compacted","payload":{"message":"Summary"}}
    {"type":"compacted","payload":{"message":"Second summary"}}
    """
    try store.write(fixture + "\n" + continuation, id: paginatedID)
    let result = try store.reader.readSession(SessionID(source: "codex", value: paginatedID))
    #expect(result.transcript.compactMap(\.recordedIndex) == [0, 1, 2, 3, 7, 8])
    #expect(result.transcript.last?.blocks == [.text("Revised answer")])
    #expect(result.conversation.last?.blocks == [.text("Second summary")])

    let snapshot = """
    {"type":"session_meta","payload":{"id":"\(legacyID)","source":"cli"}}
    {"type":"compacted","payload":{"message":"Only surviving context"}}
    {"type":"event_msg","payload":{"type":"agent_message","message":"Continued reply"}}
    """
    try store.write(snapshot)
    let rotated = try store.reader.readSession(SessionID(source: "codex", value: legacyID))
    #expect(rotated.transcript.map(\.blocks) == [[.text("Only surviving context")], [.text("Continued reply")]])
}

@Test func codexDiscoveryValidatesScopeAndUsesTheIndexOnlyForNames() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    let fixture = try store.fixture("legacy")
    let archived = try store.fixture("paginated")
    try store.write(archived, id: paginatedID, directory: "archived_sessions")
    let sid = SessionID(source: "codex", value: legacyID)
    let allowed = CodexReader(homeDirectory: store.home, includeArchived: true, accountID: "account", userID: "owner")
    let index = store.home.appendingPathComponent("session_index.jsonl")
    try Data("""
    {"id":"\(legacyID)","thread_name":"First"}
    {"id":"\(legacyID)","thread_name":"Renamed"}
    {"id":"ffffffff-ffff-ffff-ffff-ffffffffffff","thread_name":"Index only"}
    """.utf8).write(to: index)
    let tagged = fixture.replacingOccurrences(of: #""source":"cli""#,
        with: #""source":"cli","account_scoped":true,"creator_account_id":"account","creator_user_id":"owner""#)
    try store.write(tagged)
    for reader in [store.reader, CodexReader(homeDirectory: store.home, accountID: "account", userID: "other"),
                   CodexReader(homeDirectory: store.home, accountID: "wrong", userID: "owner")] {
        #expect(try reader.listSessions().isEmpty)
        #expect(throws: SessionReadError.sessionNotFound(sid)) { try reader.readSession(sid) }
    }
    #expect(try Set(allowed.listSessions().map(\.id.value)) == [legacyID, paginatedID])
    #expect(try allowed.readSession(sid).info?.title == "Renamed")
    for origin in [#""source":{"subagent":"review"}"#, #""source":"exec","thread_source":"guardian_review""#] {
        try store.write(fixture.replacingOccurrences(of: #""source":"cli""#, with: origin))
        #expect(throws: SessionReadError.sessionNotFound(sid)) { try allowed.readSession(sid) }
    }
    try store.write(archived) // Header UUID disagrees with filename.
    #expect(try store.reader.listSessions().isEmpty)
    #expect(throws: SessionReadError.sessionNotFound(sid)) { try store.reader.readSession(sid) }
    #expect(throws: SessionReadError.invalidSessionID("../sessions")) {
        try store.reader.readSession(SessionID(source: "codex", value: "../sessions"))
    }
    #expect(throws: SessionReadError.unsupportedSource("other")) {
        try store.reader.readSession(SessionID(source: "other", value: legacyID))
    }
}

@Test func codexRevertAndForkReadTheReferencedPhysicalPrefix() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    try store.write(store.fixture("paginated"), id: paginatedID)
    let segment = "019a9999-0000-7000-8000-000000000003"
    let fork = "019a9999-0000-7000-8000-000000000004"
    // Codex 0.169.1 reverts before the second turn by starting a new segment at ordinal 12.
    let reverted = """
    {"ordinal":12,"type":"session_meta","payload":{"id":"\(paginatedID)","source":"cli","history_base":{"thread_id":"\(paginatedID)","end_ordinal_exclusive":12,"end_byte_offset":2805}}}
    {"ordinal":13,"type":"event_msg","payload":{"type":"task_started","turn_id":"third"}}
    {"ordinal":14,"type":"response_item","payload":{"type":"message","id":"new","role":"user","content":[{"type":"input_text","text":"Continue"}]}}
    """
    try store.write(reverted, id: paginatedID + "_" + segment)
    let reader = store.reader
    let history = try reader.readSession(SessionID(source: "codex", value: paginatedID))
    #expect(history.conversation.compactMap(\.recordedIndex) == [0, 1, 2, 3, 7])
    #expect(history.transcript.compactMap(\.recordedIndex) == [0, 1, 2, 3, 7])
    #expect(history.recordedMessages.count == 8)
    let forked = """
    {"ordinal":15,"type":"session_meta","payload":{"id":"\(fork)","forked_from_id":"\(paginatedID)","history_base":{"thread_id":"\(segment)","end_ordinal_exclusive":15}}}
    {"ordinal":16,"type":"response_item","payload":{"type":"message","id":"fork-reply","role":"assistant","content":[{"type":"output_text","text":"Fork reply"}]}}
    """
    try store.write(forked, id: fork)
    let result = try reader.readSession(SessionID(source: "codex", value: fork))
    #expect(result.recordedMessages.count == 6)
    #expect(result.conversation.compactMap(\.recordedIndex) == Array(0..<6))
    #expect(result.transcript.compactMap(\.recordedIndex) == Array(0..<6))
    #expect(result.conversation.suffix(2).map(\.id) == ["new", "fork-reply"])
    #expect(try Set(reader.listSessions().map(\.id.value)) == [paginatedID, fork])

    try store.write(forked.replacingOccurrences(of: segment, with: fork), id: fork)
    #expect(throws: SessionReadError.incompleteHistory(SessionID(source: "codex", value: fork))) {
        try reader.readSession(SessionID(source: "codex", value: fork))
    }
}

@Test func codexKeepsRepeatedPromptsAndSkipsIncompleteFinalWrites() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    let text = """
    {"type":"session_meta","payload":{"id":"\(legacyID)","source":"cli"}}
    {"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"instructions"}]}}
    {"type":"event_msg","payload":{"type":"task_started","turn_id":"one"}}
    {"type":"event_msg","payload":{"type":"user_message","message":"same"}}
    {"type":"event_msg","payload":{"type":"user_message","message":"same"}}
    {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"same"}]}}
    {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"same"}]}}
    {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"run","name":"do_work","input":"raw input"}}
    {"type":"event_msg","payload":{"type":"exec_command_end","call_id":"run","exit_code":2}}
    {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"run","output":[{"type":"text","text":"failed"}]}}
    """
    let file = try store.write(text + "\n" + #"{"type":"response_item""#)
    let id = SessionID(source: "codex", value: legacyID)
    let before = try store.reader.readSession(id)
    #expect(before.conversation.map(\.blocks) == [
        [.text("same")], [.text("same")], [.toolCall(id: "run", name: "do_work", inputJSON: Data(#""raw input""#.utf8))],
        [.toolResult(callID: "run", contentJSON: Data(#"[{"text":"failed","type":"text"}]"#.utf8), isError: true)]
    ])
    let output = try FileHandle(forWritingTo: file)
    try output.seekToEnd()
    try output.write(contentsOf: Data(#","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}}"#.utf8))
    try output.close()
    let after = try store.reader.readSession(id)
    #expect(after.recordedMessages.dropLast().map(\.id) == before.recordedMessages.map(\.id))
    #expect(after.recordedMessages.last?.blocks == [.text("ok")])
}

@Test func codexUsesCompletedToolItemsWhenTheModelCallWasNotRecorded() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    try store.write("""
    {"type":"session_meta","payload":{"id":"\(legacyID)"}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"standalone","command":"example","exit_code":1,"aggregated_output":"failed"}}}
    {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"wrapper","name":"batch","input":"work"}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"child","command":"inner","exit_code":0}}}
    {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"wrapper","output":"ok"}}
    """)
    let history = try store.reader.readSession(SessionID(source: "codex", value: legacyID))
    #expect(history.recordedMessages.first?.toolEvents.first?.exitCode == 1)
    #expect(history.recordedMessages.map(\.blocks) == [
        [.toolCall(id: "standalone", name: "exec_command", inputJSON: Data(#""example""#.utf8))],
        [.toolResult(callID: "standalone", contentJSON: Data(#""failed""#.utf8), isError: true)],
        [.toolCall(id: "wrapper", name: "batch", inputJSON: Data(#""work""#.utf8))],
        [.toolResult(callID: "wrapper", contentJSON: Data(#""ok""#.utf8), isError: false)]
    ])
}

@Test func codexKeepsCompletedScriptEventsWithoutAddingModelCalls() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    try store.write("""
    {"type":"session_meta","payload":{"id":"\(legacyID)"}}
    {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"script","name":"exec","input":"run()"}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"one","command":"swift test","exit_code":1,"status":"failed"}}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"one","command":"swift test","exit_code":1,"status":"failed"}}}
    {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"second","name":"exec","input":"other()"}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"unowned","command":"overlap"}}}
    {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"second","output":"ok"}}
    {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"script","output":"ok"}}
    """)
    let history = try store.reader.readSession(SessionID(source: "codex", value: legacyID))
    #expect(history.recordedMessages.count == 4)
    let events = history.conversation.flatMap(\.toolEvents)
    #expect(events.map(\.id) == ["one"])
    #expect(events.first?.exitCode == 1)
    #expect(events.first?.isError == true)
}

@Test func codexMatchesDelayedAndEarlyCompletionsByCallIDAcrossTurns() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    try store.write("""
    {"type":"session_meta","payload":{"id":"\(legacyID)"}}
    {"type":"response_item","payload":{"type":"function_call","id":"first","call_id":"a","name":"functions.exec_command","arguments":"{}"}}
    {"type":"response_item","payload":{"type":"function_call_output","call_id":"a","output":"finished"}}
    {"type":"event_msg","payload":{"type":"turn_complete"}}
    {"type":"response_item","payload":{"type":"custom_tool_call","id":"wrapper","call_id":"script","name":"exec","input":"run()"}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"ui-a","call_id":"a","exit_code":1}}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"child","command":"inner"}}}
    {"type":"response_item","payload":{"type":"custom_tool_call","id":"second","call_id":"s2","name":"exec","input":"other()"}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"p","status":"completed"}}}
    {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"script","output":"ok"}}
    {"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"s2","output":"ok"}}
    {"type":"event_msg","payload":{"type":"turn_complete"}}
    {"type":"response_item","payload":{"type":"custom_tool_call","id":"patch","call_id":"p","name":"apply_patch","input":"patch"}}
    """)
    let history = try store.reader.readSession(SessionID(source: "codex", value: legacyID))
    let messages = history.conversation
    #expect(messages.count == 7)
    #expect(messages.first { $0.id == "first" }?.toolEvents.first?.exitCode == 1)
    #expect(messages[1].blocks == [.toolResult(callID: "a", contentJSON: Data(#""finished""#.utf8), isError: true)])
    #expect(messages.first { $0.id == "wrapper" }?.toolEvents.map(\.id) == ["child"])
    #expect(messages.first { $0.id == "second" }?.toolEvents.isEmpty == true)
    #expect(messages.first { $0.id == "patch" }?.toolEvents.map(\.id) == ["p"])
}

@Test func codexLeavesReusedAndRolledBackCallIDsUnattributed() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    try store.write("""
    {"type":"session_meta","payload":{"id":"\(legacyID)"}}
    {"type":"event_msg","payload":{"type":"user_message","message":"First turn"}}
    {"type":"response_item","payload":{"type":"function_call","call_id":"old","name":"exec_command","arguments":"{}"}}
    {"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}
    {"type":"response_item","payload":{"type":"function_call","call_id":"twice","name":"exec_command","arguments":"{}"}}
    {"type":"response_item","payload":{"type":"function_call_output","call_id":"twice","output":"ok"}}
    {"type":"response_item","payload":{"type":"custom_tool_call","call_id":"script","name":"exec","input":"run()"}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"old","exit_code":1}}}
    {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"twice","exit_code":1}}}
    {"type":"response_item","payload":{"type":"function_call","call_id":"twice","name":"exec_command","arguments":"{}"}}
    """)
    let history = try store.reader.readSession(SessionID(source: "codex", value: legacyID))
    #expect(history.recordedMessages.flatMap(\.toolEvents).isEmpty)
}

@Test func codexRefusesAnUnavailableOrOutOfScopeForkBase() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    let forkID = SessionID(source: "codex", value: paginatedID)
    try store.write("""
    {"ordinal":5,"type":"session_meta","payload":{"id":"\(paginatedID)","history_base":{"thread_id":"\(legacyID)","end_ordinal_exclusive":5}}}
    """, id: paginatedID)
    let scoped = """
    {"ordinal":0,"type":"session_meta","payload":{"id":"\(legacyID)","account_scoped":true,"creator_account_id":"a"}}
    {"ordinal":1,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Scoped prompt"}]}}
    """
    try store.write(scoped)
    #expect(try store.reader.listSessions().map(\.title) == [paginatedID])
    #expect(throws: SessionReadError.incompleteHistory(forkID)) { try store.reader.readSession(forkID) }
    // Even with the correct account, this copy ends before the fork's declared cutoff.
    let matching = CodexReader(homeDirectory: store.home, accountID: "a")
    #expect(throws: SessionReadError.incompleteHistory(forkID)) { try matching.readSession(forkID) }
}

@Test func localAccountChoicesRespectThreadIdentityAndOptionalOwners() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    func write(_ id: String, _ fields: String, archived: Bool = false) throws {
        let row = """
        {"type":"session_meta","payload":{"id":"\(id)","cwd":"/sample","account_scoped":true,"creator_account_id":"team",\(fields)}}
        """
        try store.write(row, id: id, directory: archived ? "archived_sessions" : "sessions/2026/01/02")
    }
    try write(legacyID, #""creator_user_id":null"#)
    #expect(try store.reader.localAccounts().count == 1)
    #expect(try store.reader.localAccounts().first?.userID == nil)
    try write(paginatedID, #""creator_user_id":"first""#)
    try write(UUID().uuidString.lowercased(), #""creator_user_id":"second""#, archived: true)
    try write(UUID().uuidString.lowercased(), #""creator_user_id":"hidden","thread_source":"subagent""#)
    try write(UUID().uuidString.lowercased(), #""creator_user_id":42"#)
    try write(UUID().uuidString.lowercased(), #""creator_user_id":"first""#)
    #expect(try store.reader.localAccounts().compactMap(\.userID) == ["first"])
    let accounts = try CodexReader(homeDirectory: store.home, includeArchived: true).localAccounts()
    #expect(Set(accounts.compactMap(\.userID)) == ["first", "second"])
    #expect(accounts.count == 2 && accounts.allSatisfy { $0.lastWorkingDirectory == "/sample" })
    #expect(try store.reader.listSessions().isEmpty)
}

@Test func codexCatalogIsSharedByScopedReadsAndRefreshedOnTheNextPass() throws {
    let store = CodexStore()
    defer { store.cleanUp() }
    try store.write(store.fixture("legacy"))
    let snapshot = try store.reader.catalogSnapshot()
    let scoped = snapshot.scoped(accountID: nil, userID: nil)
    let first = try #require(scoped.listSessions().first)
    #expect(try scoped.readSession(first.id).conversation.map(\.blocks) == store.reader.readSession(first.id).conversation.map(\.blocks))
    try store.write(store.fixture("paginated"), id: paginatedID)
    #expect(try scoped.listSessions().map(\.id) == [first.id])
    #expect(try snapshot.catalogSnapshot().listSessions().count == 2)
}
