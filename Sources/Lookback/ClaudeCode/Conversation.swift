import Foundation

// Adapted from Anthropic's Claude Agent SDK session reader. See ThirdParty/ClaudeAgentSDK-LICENSE.
struct Conversation {
    let entries: [Entry]
    // Preserve first insertion order and use the last record for each UUID, as the SDK does.
    private var position: [String: Int] = [:]
    private var orderedIDs: [String] = []
    private var parents: Set<String> = []

    init(_ entries: [Entry]) {
        self.entries = entries
        for (index, entry) in entries.enumerated() {
            if position.updateValue(index, forKey: entry.id) == nil { orderedIDs.append(entry.id) }
            if let parent = entry.parent { parents.insert(parent) }
        }
    }

    func messages() -> [SessionMessage] {
        var latestVisible: Entry?
        var latestAny: Entry?
        func isLater(_ entry: Entry, than previous: Entry?) -> Bool {
            guard let previous else { return true }
            return position[entry.id, default: -1] > position[previous.id, default: -1]
        }
        for terminal in entries where !parents.contains(terminal.id) {
            var cursor: Entry? = terminal
            var visited = Set<String>()
            while let entry = cursor, visited.insert(entry.id).inserted {
                if entry.isMessage {
                    if isLater(entry, than: latestAny) { latestAny = entry }
                    if entry.message != nil, isLater(entry, than: latestVisible) { latestVisible = entry }
                    break
                }
                cursor = lookup(entry.parent)
            }
        }
        guard let leaf = latestVisible ?? latestAny else { return [] }
        var chain: [Entry] = []
        var seen = Set<String>()
        var current: Entry? = leaf
        while let entry = current, seen.insert(entry.id).inserted {
            chain.append(entry)
            // A compaction boundary has no physical parent. Its logical parent is archival.
            current = lookup(entry.parent)
        }
        chain.reverse()
        return recoveringToolTurns(chain, seen: seen).compactMap(\.message)
    }

    private func lookup(_ id: String?) -> Entry? {
        guard let id, let index = position[id] else { return nil }
        return entries[index]
    }

    private func recoveringToolTurns(_ chain: [Entry], seen chainIDs: Set<String>) -> [Entry] {
        var anchors: [String: String] = [:]
        var responses: [String] = []
        for entry in chain {
            guard let response = entry.response else { continue }
            if anchors.updateValue(entry.id, forKey: response) == nil { responses.append(response) }
        }
        guard !responses.isEmpty else { return chain }

        var siblings: [String: [Entry]] = [:]
        var owners: [String: Entry] = [:]
        var ambiguous = Set<String>()
        var resultRows: [Entry] = []
        for id in orderedIDs {
            guard let entry = lookup(id) else { continue }
            if let response = entry.response {
                siblings[response, default: []].append(entry)
                for call in entry.calls {
                    if let previous = owners[call], previous.response != response { ambiguous.insert(call) }
                    owners[call] = entry
                }
            } else if entry.type == "user", entry.carriesResult, let parent = entry.parent, !parent.isEmpty {
                resultRows.append(entry)
            }
        }
        for call in ambiguous { owners.removeValue(forKey: call) }
        var linked: [String: [Entry]] = [:]
        for result in resultRows {
            if let parent = result.parent { linked[parent, default: []].append(result) }
            if let source = lookup(result.sourceAssistant), result.sameWriter(as: source) {
                linked[source.id, default: []].append(result)
            }
            for call in result.results {
                if let owner = owners[call], result.sameWriter(as: owner) {
                    linked[owner.id, default: []].append(result)
                }
            }
        }
        let answeredOnChain = Set(chain.flatMap(\.results))
        let fileOrder = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        var seen = chainIDs
        var insertions: [String: [Entry]] = [:]
        for response in responses {
            guard let group = siblings[response], let anchor = anchors[response] else { continue }
            let members = Set(group.map(\.id))
            let missing = group.filter { !seen.contains($0.id) }
            var direct: [Entry] = []
            var strays: [Entry] = []
            var collected = Set<String>()
            for entry in group {
                for result in linked[entry.id] ?? [] where !seen.contains(result.id) && collected.insert(result.id).inserted {
                    if let parent = result.parent, members.contains(parent) { direct.append(result) }
                    else { strays.append(result) }
                }
            }
            if !strays.isEmpty {
                var answered = answeredOnChain
                for result in direct { answered.formUnion(result.results) }
                for result in strays.sorted(by: { fileOrder[$0.id, default: 0] < fileOrder[$1.id, default: 0] }) {
                    let matches = result.results.contains { call in
                        guard !answered.contains(call), let owner = owners[call] else { return false }
                        return members.contains(owner.id)
                    }
                    if matches {
                        direct.append(result)
                        answered.formUnion(result.results)
                    }
                }
            }
            guard !missing.isEmpty || !direct.isEmpty else { continue }
            let recovered = missing.sorted { $0.timestamp < $1.timestamp } + direct.sorted { $0.timestamp < $1.timestamp }
            seen.formUnion(recovered.map(\.id))
            insertions[anchor] = recovered
        }
        guard !insertions.isEmpty else { return chain }
        var result: [Entry] = []
        for entry in chain {
            result.append(entry)
            if let added = insertions[entry.id] { result.append(contentsOf: added) }
        }
        return result
    }
}
