import Foundation

/// Recorded messages stay in file order. Turn edits affect only the active projection.
struct CodexHistory {
    private struct Occurrence {
        var item: CodexItem
        var representations: Set<Int>
        var ids: Set<String>
        let ordinal: Int
        let timestamp: Date?
    }

    fileprivate enum Edit {
        case append(Int)
        case replace([Int])
    }

    fileprivate struct Turn {
        let id: String?
        var edits: [Edit] = []
        var hasUser = false
    }

    private var pending: [Occurrence] = []
    private var turns: [Turn] = []
    private var explicitTurn = false
    private var active: [Int] = []
    private var aliases: [Set<String>] = []
    private var recorded: [SessionMessage] = []
    private var ordinal = 0
    private var segment = ""
    private var failedCalls: Set<String> = []
    private var completions: [String: SessionToolEvent] = [:]
    private var inFlight: [String: Int] = [:]

    struct Checkpoint {
        fileprivate var turns: [Turn] = []
        fileprivate var active: [Int] = []
        fileprivate var explicitTurn = false
    }

    mutating func checkpoint() -> Checkpoint {
        flush()
        return Checkpoint(turns: turns, active: active, explicitTurn: explicitTurn)
    }

    mutating func beginSegment(_ segmentID: String, at base: Checkpoint) {
        flush()
        turns = base.turns
        active = base.active
        explicitTurn = base.explicitTurn
        segment = segmentID
        ordinal = 0
    }

    mutating func observe(_ row: Row) {
        ordinal = row["ordinal"] as? Int ?? (ordinal + 1)
        guard let type = row["type"] as? String, let payload = row["payload"] as? Row else { return }
        let timestamp = transcriptDate(row["timestamp"] as? String)
        let event = payload["type"] as? String
        switch (type, event) {
        case ("event_msg", "task_started"), ("event_msg", "turn_started"):
            startTurn(payload["turn_id"] as? String)
        case ("turn_context", _):
            if let id = payload["turn_id"] as? String, turns.last?.id != id { startTurn(id) }
        case ("event_msg", "task_complete"), ("event_msg", "turn_complete"), ("event_msg", "turn_aborted"):
            flush()
            explicitTurn = false
        case ("event_msg", "thread_rolled_back"):
            flush()
            guard let count = payload["num_turns"] as? Int, count > 0 else { return }
            let users = turns.indices.filter { turns[$0].hasUser }
            if let from = users.suffix(count).first { discardTurns(from: from) }
        case ("compacted", _):
            flush()
            compact(payload, timestamp: timestamp)
        default:
            if let item = CodexItem.decode(type: type, payload: payload) {
                enqueue(item, timestamp: timestamp)
                if let key = item.toolKey {
                    inFlight[key.id] = key.output ? nil : pending.indices.last
                }
            } else if type == "event_msg" {
                let completion = CodexItem.completionEvent(payload)
                if inFlight.count == 1, let (callID, index) = inFlight.first,
                   case let .toolCall(_, name, _) = pending[index].item.blocks.first, ["exec", "functions.exec"].contains(name),
                   let event = completion, event.id != callID {
                    // Keep the provider's completion as context without inventing an extra model call.
                    if !pending[index].item.toolEvents.contains(where: { $0.id == event.id }) {
                        pending[index].item.toolEvents.append(event)
                    }
                    return
                }
                for item in CodexItem.completedTool(payload) {
                    guard let key = item.toolKey else { continue }
                    // A custom tool can report many child processes under its single model call.
                    guard inFlight.isEmpty || inFlight[key.id] != nil else { continue }
                    if !key.output, let completion { completions[key.id] = completion }
                    if case .toolResult(_, _, true) = item.blocks.first { failedCalls.insert(key.id) }
                    enqueue(item, timestamp: timestamp)
                }
            }
        }
    }

    mutating func finish(info: SessionInfo) -> SessionHistory {
        flush()
        // The remaining turns already reflect rollbacks and the selected segment's fork point.
        // A context replacement changes what the model sees, not what was said on that branch.
        var transcript: [Int] = []
        for turn in turns {
            for edit in turn.edits {
                switch edit {
                case let .append(index): transcript.append(index)
                case let .replace(indices):
                    // A rotated file may start with a snapshot as its only surviving history.
                    if transcript.isEmpty { transcript = indices }
                }
            }
        }
        return SessionHistory(id: info.id, conversation: active.map { recorded[$0] }, recordedMessages: recorded,
                              info: info, transcript: transcript == active ? nil : transcript.map { recorded[$0] })
    }

    private mutating func startTurn(_ id: String?) {
        if explicitTurn, let id, turns.last?.id == id { return }
        flush()
        turns.append(Turn(id: id))
        explicitTurn = true
    }

    private mutating func discardTurns(from index: Int) {
        turns.removeSubrange(index...)
        active.removeAll()
        for turn in turns {
            for edit in turn.edits {
                switch edit {
                case let .append(index): active.append(index)
                case let .replace(indices): active = indices
                }
            }
        }
        explicitTurn = false
    }

    private mutating func enqueue(_ item: CodexItem, timestamp: Date?) {
        // Some early rollouts have no turn boundaries. A prompt after a reply starts a new turn.
        if !explicitTurn, item.role == .user, let last = pending.last, last.item.role != .user { flush() }
        // Pair each representation at most once. Two identical prompts in a turn are still two occurrences.
        let rep = item.representation.rawValue
        let isChat = item.role == .user || (item.role == .assistant && item.text != nil)
        func available(_ other: Occurrence) -> Bool {
            other.item.role == item.role && !other.representations.contains(rep)
        }
        let byID = isChat ? item.nativeID.flatMap { id in pending.firstIndex { available($0) && $0.ids.contains(id) } } : nil
        if isChat, let index = byID ?? pending.firstIndex(where: { other in
            available(other) && (other.item.blocks == item.blocks || (item.text != nil && other.item.text == item.text))
        }) {
            pending[index].representations.insert(rep)
            if let id = item.nativeID { pending[index].ids.insert(id) }
            if rep > pending[index].item.representation.rawValue { pending[index].item = item }
            return
        }
        pending.append(Occurrence(item: item, representations: [rep], ids: Set([item.nativeID].compactMap { $0 }),
                                  ordinal: ordinal, timestamp: timestamp))
    }

    private mutating func flush() {
        // Prefer the model's arguments and exact output. A completed item can supply either missing half.
        var tools: [CodexItem.ToolKey: Int] = [:]
        for (index, entry) in pending.enumerated() {
            guard let key = entry.item.toolKey else { continue }
            if let old = tools[key] {
                let prior = pending[old].item.representation
                if prior == .response || (entry.item.representation != .response && prior.rawValue >= entry.item.representation.rawValue) { continue }
            }
            tools[key] = index
        }
        for (offset, entry) in pending.enumerated() {
            if let key = entry.item.toolKey, entry.item.representation != .response, tools[key] != offset { continue }
            if turns.isEmpty || (!explicitTurn && entry.item.role == .user && turns.last?.hasUser == true) {
                turns.append(Turn(id: nil))
            }
            if entry.item.role == .user { turns[turns.count - 1].hasUser = true }
            let index = record(entry.item, ids: entry.ids, fallback: "\(segment):row-\(entry.ordinal)", timestamp: entry.timestamp)
            turns[turns.count - 1].edits.append(.append(index))
            active.append(index)
        }
        pending.removeAll(keepingCapacity: true)
        completions.removeAll()
        failedCalls.removeAll()
        inFlight.removeAll()
    }

    private mutating func record(_ item: CodexItem, ids: Set<String>, fallback: String, timestamp: Date?) -> Int {
        let index = recorded.count
        let blocks = item.blocks.map { block in
            if case let .toolResult(call, data, _) = block, failedCalls.contains(call) {
                return MessageBlock.toolResult(callID: call, contentJSON: data, isError: true)
            }
            return block
        }
        var events = item.toolEvents
        if let key = item.toolKey, !key.output, let completion = completions[key.id] { events.append(completion) }
        recorded.append(SessionMessage(id: item.nativeID ?? ids.sorted().first ?? fallback, parentID: nil, timestamp: timestamp,
                                       role: item.role, blocks: blocks, isCompactionSummary: item.summary, recordedIndex: index, toolEvents: events))
        aliases.append(ids)
        return index
    }

    private mutating func compact(_ payload: Row, timestamp: Date?) {
        let summary = payload["message"] as? String
        var items = (payload["replacement_history"] as? [Row] ?? []).compactMap(CodexItem.response)
        // Older rollouts store a readable summary as the final user message in the replacement.
        if let summary, !summary.isEmpty, let last = items.last, last.role == .user, last.text == summary {
            items[items.count - 1] = .marker(id: last.nativeID, text: summary)
        }
        if !items.contains(where: \.summary) {
            items.append(.marker(id: nil, text: summary))
        }

        // Match retained occurrences from the end so repeated ID-less prompts keep their most recent indices.
        var matches = Array<Int?>(repeating: nil, count: items.count)
        var end = active.endIndex
        for i in items.indices.reversed() {
            let item = items[i]
            let match = active[..<end].lastIndex { index in
                let previous = recorded[index]
                guard previous.role == item.role else { return false }
                if let id = item.nativeID, !aliases[index].isEmpty { return aliases[index].contains(id) }
                return previous.blocks == item.blocks && !item.summary
            }
            if let match { matches[i] = active[match]; end = match }
        }
        active = items.enumerated().map { offset, item in
            if let match = matches[offset] { return match }
            let ids = Set([item.nativeID].compactMap { $0 })
            return record(item, ids: ids, fallback: "\(segment):row-\(ordinal)-\(offset)", timestamp: timestamp)
        }
        if turns.isEmpty { turns.append(Turn(id: nil)) }
        turns[turns.count - 1].edits.append(.replace(active))
    }
}
