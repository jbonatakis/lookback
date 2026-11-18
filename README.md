# Lookback

Lookback is a read-only Swift library for exploring local coding-agent sessions. Its first provider reads Claude Code. The package requires Swift 6 and targets macOS 13 and later. It uses Foundation and has no external package dependencies.

## Try the example

Run these commands from the Lookback repository.

```sh
swift run lookback-demo                # Preview the most recently updated session
swift run lookback-demo --list         # List sessions with IDs and titles
swift run lookback-demo SESSION_ID     # Preview a session by its ID
```

The [example program](Examples/LookbackDemo/main.swift) shows recent conversation excerpts, the most-used tools, and message counts for the active conversation and the full recorded history.

## Read a session

Add `.package(path: "../lookback")` to a sibling Swift package's dependencies and `.product(name: "Lookback", package: "lookback")` to the consuming target.

```swift
import Lookback

func recentConversation(using reader: any SessionReader) throws -> [SessionMessage] {
    guard let latest = try reader.listSessions().first else { return [] }
    return try reader.readSession(latest.id).conversation
}

let messages = try recentConversation(using: ClaudeCodeReader())
```

The default reader opens `$CLAUDE_CONFIG_DIR/projects` when configured and otherwise uses `~/.claude/projects`. Pass `ClaudeCodeReader(projectsDirectory: url)` to read another projects store. Reads are synchronous. Run them off the main thread in a UI.

## Choose a view

- Use `conversation` to show what remained in the conversation on its selected branch. Compaction summaries are marked explicitly. Tool calls and their parallel results are linked back into the conversation.
- Use `recordedMessages` to reconstruct activity over time. It includes visible messages from earlier context and abandoned branches in file order. Both views can contain the same messages. Use the session ID and message ID together when indexing them.
- A message has a source-local ID, optional parent and timestamp, role, and ordered content blocks. Text, tool calls, and tool results are represented directly. Tool inputs and result contents are UTF-8 JSON. Other block types retain their type and position. Message parents can refer to internal records omitted from either view.
- Session discovery returns top-level sessions with a usable title or prompt, ordered by modification time. It samples the ends of each transcript and falls back to a full scan when it cannot find a title in the sample. Nested subagent transcripts have separate files and are outside the current API. Missing stores produce an empty listing. Malformed JSON lines, including an unfinished final write, are skipped.

## Additional providers

A provider implements `SessionReader`, declares a stable source identifier, and maps its native session store into `SessionInfo` and `SessionHistory`. Session IDs carry their source. File discovery, native ID validation, and transcript reconstruction are internal to each provider. The Claude implementation is in `Sources/Lookback/ClaudeCode/`. A future Codex provider can use its own layout and reconstruction rules.

## Compatibility

The Claude Code file format can evolve. Conversation selection and parallel-tool recovery follow the pinned [Anthropic session reader](https://github.com/anthropics/claude-agent-sdk-python/blob/8ed58affbee28a201bb5aeb34afcd513415acac5/src/claude_agent_sdk/_internal/sessions.py). Its MIT notice is included in [ThirdParty/ClaudeAgentSDK-LICENSE](ThirdParty/ClaudeAgentSDK-LICENSE).

Run `swift test` with a Swift 6 toolchain that includes Swift Testing. Tests use synthetic transcripts in temporary directories.

On a Mac using Apple's standalone Command Line Tools, SwiftPM may need the installed Testing framework path. This command runs the suite on that setup.

```sh
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
swift test --disable-xctest --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks"
```
