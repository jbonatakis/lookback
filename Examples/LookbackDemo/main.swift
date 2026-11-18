import Foundation
import Lookback

// Keep prompts and replies readable in a terminal, even when they contain code or line breaks.
func preview(_ text: String, limit: Int = 120) -> String {
    let clean = text.components(separatedBy: .controlCharacters).joined(separator: " ")
    let line = clean.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let prefix = line.prefix(limit)
    return prefix.endIndex == line.endIndex ? line : "\(prefix)…"
}

func show(_ history: SessionHistory) {
    print(preview(history.info?.title ?? history.id.value))
    if let session = history.info, let directory = session.workingDirectory {
        print(preview(directory + (session.gitBranch.map { "  [\($0)]" } ?? "")))
    }
    print("\(history.conversation.count) messages in the active conversation · \(history.recordedMessages.count) recorded")

    var tools: [String: Int] = [:]
    for message in history.conversation {
        for case let .toolCall(_, name, _) in message.blocks {
            tools[name, default: 0] += 1
        }
    }
    if !tools.isEmpty {
        let ranked = tools.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        print("Top tools  " + ranked.prefix(5).map { "\(preview($0.key)) ×\($0.value)" }.joined(separator: ", "))
    }

    // Walk backwards so long sessions only need a handful of text previews.
    var excerpts: [String] = []
    for message in history.conversation.reversed() {
        let speaker: String
        switch message.role {
        case .user: speaker = "You"
        case .assistant: speaker = "Claude"
        case .system: speaker = message.isCompactionSummary ? "Compaction summary" : "System"
        case .tool: continue
        }
        for case let .text(text) in message.blocks {
            let excerpt = preview(text)
            guard !excerpt.isEmpty else { continue }
            excerpts.append("\(speaker)  \(excerpt)")
            break
        }
        if excerpts.count == 6 { break }
    }
    if excerpts.isEmpty {
        print("\nNo text excerpts in this conversation.")
    } else {
        print("\nRecent conversation")
        for line in excerpts.reversed() { print(line) }
    }
}

func run(_ arguments: [String]) throws {
    let usage = "Usage: swift run lookback-demo [--list | SESSION_ID]"
    if arguments == ["--help"] || arguments == ["-h"] { print(usage); return }
    guard arguments.count <= 1 else { fail(usage) }

    let reader = ClaudeCodeReader()
    if let id = arguments.first, id != "--list" {
        show(try reader.readSession(SessionID(source: reader.source, value: id)))
        return
    }
    let sessions = try reader.listSessions()
    if arguments == ["--list"] {
        for session in sessions {
            let updated = session.modifiedAt.formatted(date: .abbreviated, time: .shortened)
            print("\(session.id.value)  \(updated)  \(preview(session.title, limit: 72))")
        }
        if sessions.isEmpty { print("No Claude Code sessions found.") }
    } else if let latest = sessions.first {
        show(try reader.readSession(latest.id))
    } else {
        print("No Claude Code sessions found.")
    }
}

func fail(_ description: String) -> Never {
    FileHandle.standardError.write(Data((description + "\n").utf8))
    exit(1)
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch SessionReadError.invalidSessionID, SessionReadError.sessionNotFound {
    fail("Unknown session. Use --list to see available IDs.")
} catch {
    fail("Could not read Claude Code history: \(error.localizedDescription)")
}
