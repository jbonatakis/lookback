import Foundation

/// Paginated rollouts refer to their predecessor by physical segment UUID and exclusive ordinal.
struct CodexSegment {
    struct Base: Hashable {
        let key: String
        let end: Int
    }

    let key: String
    let file: URL
    let modified: Date
    let threadID: String
    let cwd: String?
    let branch: String?
    let createdAt: Date?
    let base: Base?

    init(key: String, file: URL, modified: Date, header: Row, id: SessionID) throws {
        self.key = key
        self.file = file
        self.modified = modified
        threadID = (header["id"] as? String ?? "").lowercased()
        cwd = header["cwd"] as? String
        branch = (header["git"] as? Row)?["branch"] as? String
        createdAt = transcriptDate(header["timestamp"] as? String)
        if let pointer = header["history_base"], !(pointer is NSNull) {
            guard let fields = pointer as? Row, let value = fields["thread_id"] as? String,
                  let uuid = UUID(uuidString: value), let end = fields["end_ordinal_exclusive"] as? Int, end >= 0 else {
                throw SessionReadError.incompleteHistory(id)
            }
            base = Base(key: uuid.uuidString.lowercased(), end: end)
        } else { base = nil }
    }

    /// Return the exclusive end actually read so callers can distinguish a complete prefix from a truncated copy.
    func readRows(before end: Int?, id: SessionID, includes: (Row) -> Bool,
                  visit: (Int, Row) throws -> Void) throws -> Int {
        enum Boundary: Error { case end }
        var first = true
        var nextOrdinal = base?.end ?? 0
        do {
            try TranscriptFile.forEachRow(in: file) { row in
                if first {
                    // Discovery and replay use separate file handles. Validate the reopened header.
                    guard row["type"] as? String == "session_meta", let header = row["payload"] as? Row,
                          (header["id"] as? String)?.lowercased() == threadID, includes(header),
                          try CodexSegment(key: key, file: file, modified: modified, header: header, id: id).base == base else {
                        throw SessionReadError.incompleteHistory(id)
                    }
                    first = false
                }
                let ordinal = row["ordinal"] as? Int ?? nextOrdinal
                guard ordinal >= 0, ordinal < Int.max else { throw SessionReadError.incompleteHistory(id) }
                if ordinal == end { nextOrdinal = ordinal; throw Boundary.end }
                if let end, ordinal > end { throw SessionReadError.incompleteHistory(id) }
                try visit(ordinal, row)
                nextOrdinal = ordinal + 1
            }
        } catch Boundary.end {}
        guard !first else { throw SessionReadError.incompleteHistory(id) }
        return nextOrdinal
    }
}
