import Foundation
import SQLite3
import Testing
@testable import Lookback

struct AntigravityReaderTests {
    @Test func testImportAndRefreshLiveTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uuid = UUID().uuidString
        let logs = directory.appendingPathComponent("brain/\(uuid)/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("transcript_full.jsonl")
        var db: OpaquePointer?
        #expect(sqlite3_open(directory.appendingPathComponent("conversation_summaries.db").path, &db) == SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        #expect(sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE conversation_summaries(conversation_id, title, workspace_uris, last_modified_time);
            INSERT INTO conversation_summaries VALUES('\(uuid)', 'Test', '["file:///tmp/my%20project"]', '2026-01-01 00:00:00');
            """, nil, nil, nil) == SQLITE_OK)

        let initial = #"""
        {"step_index":0,"type":"USER_INPUT","content":"<USER_REQUEST>\nQuestion\n</USER_REQUEST>\n<ADDITIONAL_METADATA>private</ADDITIONAL_METADATA>"}
        broken line
        {"step_index":1,"type":"PLANNER_RESPONSE","thinking":"private","tool_calls":[{"name":"list_directory"}]}
        """#
        try initial.write(to: file, atomically: true, encoding: .utf8)
        let reader = AntigravityReader(directory: directory)
        let snapshot = try reader.catalogSnapshot()
        let info = try #require(snapshot.listSessions().first)
        #expect(info.workingDirectory == "/tmp/my project")
        let first = try snapshot.readSession(info.id)
        #expect(first.transcript.map(\.id) == ["step-0", "step-1"])
        #expect(first.transcript[0].blocks == [.text("Question")])
        #expect(first.transcript[1].blocks == [.toolCall(id: "1-0", name: "list_directory", inputJSON: nil)])

        let reply = #"{"step_index":3,"type":"PLANNER_RESPONSE","content":"Answer","thinking":"private","created_at":"2026-01-01T00:00:04Z"}"#
        try (initial + "\n" + reply + "\n" + reply).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: info.modifiedAt.addingTimeInterval(2)], ofItemAtPath: file.path)
        // AGY closes the last writer when the turn finishes, removing its WAL sidecars.
        #expect(sqlite3_close(db) == SQLITE_OK)
        db = nil
        let refreshed = try reader.catalogSnapshot()
        let next = try refreshed.readSession(info.id)
        let nextInfo = try #require(next.info)
        #expect(nextInfo.modifiedAt > info.modifiedAt)
        #expect(next.transcript.map(\.id) == ["step-0", "step-1", "step-3"])
        #expect(next.transcript.last?.blocks == [.text("Answer")])
        #expect(next.transcript.last?.parentID == "step-1")
        #expect(next.transcript.last?.recordedIndex == 2)
        #expect(next.transcript.last?.timestamp != nil)
    }
}
