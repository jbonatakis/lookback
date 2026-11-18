# Lookback

Lookback is a read-only Swift library for exploring local Claude Code and Codex sessions. The package requires Swift 6 and targets macOS 13 and later. It uses Foundation and has no external package dependencies.

## Try the example

Run these commands from the Lookback repository.

```sh
swift run lookback-demo                # Preview the most recently updated session
swift run lookback-demo --list         # List sessions with IDs and titles
swift run lookback-demo SESSION_ID     # Preview a session by its ID
swift run lookback-demo --source codex --list
swift run lookback-demo --source codex SESSION_ID
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

`ClaudeCodeReader` opens `$CLAUDE_CONFIG_DIR/projects` when configured and otherwise uses `~/.claude/projects`. Pass `ClaudeCodeReader(projectsDirectory: url)` to read another projects store. Reads are synchronous. Run them off the main thread in a UI.

## Read Codex sessions

Use `CodexReader()` with the same API. It discovers active rollouts under `$CODEX_HOME/sessions/YYYY/MM/DD/`, defaulting to `~/.codex`. To read an exported home including its archived threads, use `CodexReader(homeDirectory: url, includeArchived: true)`. Rollout headers identify top-level threads and user forks. The optional `session_index.jsonl` supplies names. The first visible prompt or the thread UUID supplies a fallback.

The default reader includes unscoped threads. To also read account-scoped threads, pass `CodexReader(accountID: accountID, userID: userID)`. Marked rollouts require a matching creator account and, when present, creator user. Use `CodexReader.localAccounts()` to discover candidate account and user pairs from local top-level rollout headers. Each choice includes the last project and modification date. Pass the selected pair to the reader. Lookback applies the same filter to discovery, direct lookup, and inherited fork history.

Codex can record a message in several forms. Lookback pairs model messages with their display events and completed items within a turn, and links tool calls and results by call ID. A native message ID is used when available. Older records get deterministic IDs derived from the rollout segment and record position.

The active view applies compaction and turn rollbacks. Paginated reverts can create another rollout segment pointing to an earlier prefix. The recorded view includes discarded turns still present in the thread's files. A fork inherits only its referenced prefix. Copy the referenced segments along with the current rollout when exporting a thread. A missing required segment produces `SessionReadError.incompleteHistory`. Opaque compaction summaries appear as system messages with a `.other(type: "compaction")` block. The Codex app server documents the corresponding [thread history operations](https://developers.openai.com/codex/app-server/).

## Choose a view

- Use `conversation` to show what remained in the conversation on its selected branch. Compaction summaries are marked explicitly. Tool calls and their parallel results are linked back into the conversation.
- Use `recordedMessages` to reconstruct activity over time. It includes visible messages from earlier context and abandoned branches in file order. A source message ID can repeat within one session. To index each occurrence, pair the session ID with its zero-based position in `recordedMessages`. Both readers supply that position as `message.recordedIndex` in both views. Positions can change if earlier records are rewritten or removed.
- A message has a source-local ID, optional parent and timestamp, role, and ordered content blocks. Text, tool calls, and tool results are represented directly. Tool inputs and result contents are UTF-8 JSON. Other block types retain their type and position. Message parents can refer to internal records omitted from either view.
- Claude Code discovery returns top-level sessions with a usable title or prompt, ordered by modification time. It skips inaccessible projects and transcripts and selects the newest readable copy of a session. It samples the ends of each transcript and falls back to a full scan when it cannot find a title in the sample. Both providers skip subagent sessions and malformed JSON lines, including an unfinished final write. Missing stores produce an empty listing.

## Additional providers

A provider implements `SessionReader`, declares a stable source identifier, and maps its native session store into `SessionInfo` and `SessionHistory`. Session IDs carry their source. File discovery, native ID validation, and transcript reconstruction are internal to each provider. See `Sources/Lookback/ClaudeCode/` and `Sources/Lookback/Codex/` for the two implementations.

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
