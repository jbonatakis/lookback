# Lookback

Lookback is a read-only Swift library for exploring local Claude Code, Codex, Pi, and Google Antigravity CLI sessions. The package requires Swift 6 and targets macOS 13 and later. It uses Foundation and has no external package dependencies.

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

## Read Pi sessions

Use `PiReader()` or `swift run lookback-demo --source pi --list` for Pi v3 JSONL sessions. By default the reader checks `~/.pi/agent/sessions`, or `$PI_CODING_AGENT_DIR/sessions` with a custom agent home. `PI_CODING_AGENT_SESSION_DIR` overrides that location. Pass `PiReader(sessionsDirectory: url)` to select a store explicitly, including one configured through Pi's `--session-dir` or `sessionDir`. The reader accepts flat stores and the default encoded project directories.

The session header supplies the project and native ID. Lookback scopes the ID to its project (`nativeID@cwd`) because Pi allows custom IDs. A saved name takes precedence over the first user prompt. The active conversation follows the last persisted leaf and applies compaction and context edits. The transcript keeps the original user and assistant exchange, tool activity and summaries on that branch. Recorded messages also include abandoned branches. Prompt setup, settings, and extension state are omitted from the exchange. Forks and clones use the history in their own file.

## Read Google Antigravity CLI sessions

Use `AntigravityReader()` or `swift run lookback-demo --source antigravity --list`. The reader discovers projects in the local SQLite catalog under `~/.gemini/antigravity-cli` and reads prompts, replies, and tool names from generated transcripts. Pass `directory:` to select a different Antigravity CLI store.

## Choose a view

- Use `conversation` to show what remained in the conversation on its selected branch. Compaction summaries are marked explicitly. Tool calls and their parallel results are linked back into the conversation.
- Use `transcript` for a conversation viewer. For Codex and Pi it keeps the original messages across compactions and follows the selected branch through rollbacks and forks. Other readers default to `conversation`.
- Use `recordedMessages` to reconstruct activity over time. It includes visible messages from earlier context and abandoned branches in file order. A source message ID can repeat within one session. To index each occurrence, pair the session ID with its zero-based position in `recordedMessages`. The readers supply that position as `message.recordedIndex` in both views. Positions can change if earlier records are rewritten or removed.
- A message has a source-local ID, optional parent and timestamp, role, and ordered content blocks. Text, tool calls, and tool results are represented directly. Tool inputs and result contents are UTF-8 JSON. Other block types retain their type and position. Message parents can refer to internal records omitted from either view.
- Claude Code messages marked by the provider as background task notifications carry optional `taskNotification` metadata (task and tool-use IDs, status, summary, and result). The original role and text blocks are preserved, including for unrecognized payloads.
- Claude Code discovery returns top-level sessions with a usable title or prompt, ordered by modification time. It skips inaccessible projects and transcripts and selects the newest readable copy of a session. It samples the ends of each transcript and falls back to a full scan when it cannot find a title in the sample. The Claude Code and Codex readers skip subagent sessions. All readers skip malformed JSON lines, including an unfinished final write. Missing stores produce an empty listing.

## Additional providers

A provider implements `SessionReader`, declares a stable source identifier, and maps its native session store into `SessionInfo` and `SessionHistory`. Session IDs carry their source. File discovery, native ID validation, and transcript reconstruction are internal to each provider. See `Sources/Lookback/ClaudeCode/` and `Sources/Lookback/Codex/` for existing implementations.

## Compatibility

The Claude Code file format can evolve. Conversation selection and parallel-tool recovery follow the pinned [Anthropic session reader](https://github.com/anthropics/claude-agent-sdk-python/blob/8ed58affbee28a201bb5aeb34afcd513415acac5/src/claude_agent_sdk/_internal/sessions.py). Its MIT notice is included in [ThirdParty/ClaudeAgentSDK-LICENSE](ThirdParty/ClaudeAgentSDK-LICENSE).

For batch imports, call `catalogSnapshot()` on a Claude Code, Codex, or Pi reader. Use that reader for listing and reading sessions during the pass. A Codex snapshot also supports `localAccounts()` and `scoped(accountID:userID:)` without rebuilding its catalog. Create a fresh snapshot for the next pass to pick up new files and title changes.

Run `swift test` with a Swift 6 toolchain that includes Swift Testing. Tests use synthetic transcripts in temporary directories.

On a Mac using Apple's standalone Command Line Tools, SwiftPM may need the installed Testing framework path. This command runs the suite on that setup.

```sh
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
swift test --disable-xctest --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks"
```
