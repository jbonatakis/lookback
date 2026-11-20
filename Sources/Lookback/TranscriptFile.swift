import Foundation

typealias Row = [String: Any]

enum TranscriptFile {
    // Directory entries from a catalog can be replaced with links between listing and reading.
    static func isRegularFile(_ url: URL, under root: URL) -> Bool {
        let base = root.standardizedFileURL.pathComponents
        let parts = url.standardizedFileURL.pathComponents
        guard parts.starts(with: base) else { return false }
        let relative = parts.dropFirst(base.count).joined(separator: "/")
        let expected = root.resolvingSymlinksInPath().appendingPathComponent(relative)
        let current = URL(fileURLWithPath: url.path)
        return expected.standardizedFileURL.path == current.resolvingSymlinksInPath().standardizedFileURL.path &&
            (try? current.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    static func firstRow(in url: URL) throws -> Row? {
        enum Found: Error { case row }
        var first: Row?
        do {
            try forEachRow(in: url) { first = $0; throw Found.row }
        } catch Found.row {}
        return first
    }

    static func forEachRow(in url: URL, _ visit: (Row) throws -> Void) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // Bound the read to the snapshot length even while the writer is appending.
        var remaining = try file.seekToEnd()
        try file.seek(toOffset: 0)
        var partial = Data()
        while remaining > 0 {
            guard let data = try file.read(upToCount: Int(min(remaining, 256 * 1024))),
                  !data.isEmpty else { break }
            remaining -= UInt64(data.count)
            var start = data.startIndex
            for end in data.indices where data[end] == 10 {
                if partial.isEmpty {
                    try parse(data[start..<end], visit)
                } else {
                    partial.append(data[start..<end])
                    try parse(partial, visit)
                    partial = Data()
                }
                start = end + 1
            }
            partial.append(data[start...])
        }
        try parse(partial, visit)
    }

    /// Read whole JSON records at both ends. Avoid splitting a multi-byte string or
    /// treating a suffix of a long record as a separate record.
    static func sample(in url: URL, _ visit: (Row) -> Void) throws -> Bool {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        let window = 65_536
        try file.seek(toOffset: 0)
        if length <= UInt64(window * 2) {
            let all = try file.read(upToCount: Int(length)) ?? Data()
            for line in all.split(separator: 10) { parse(line, visit) }
            return true
        }
        let head = try file.read(upToCount: window) ?? Data()
        guard let last = head.lastIndex(of: 10) else {
            // The first row may itself contain a long prompt and the only cwd or start date.
            try forEachRow(in: url, visit)
            return true
        }
        for line in head[..<last].split(separator: 10) { parse(line, visit) }
        // One byte of lookbehind preserves a line beginning exactly at the window.
        try file.seek(toOffset: length - UInt64(window + 1))
        let tail = try file.read(upToCount: window + 1) ?? Data()
        if let newline = tail.firstIndex(of: 10) {
            for line in tail[(newline + 1)...].split(separator: 10) { parse(line, visit) }
        }
        return false
    }

    private static func parse(_ data: Data, _ visit: (Row) throws -> Void) rethrows {
        guard !data.isEmpty, let row = try? JSONSerialization.jsonObject(with: data) as? Row else { return }
        try visit(row)
    }
}

func transcriptDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
    return try? Date.ISO8601FormatStyle().parse(value)
}

extension CocoaError {
    var isMissingFile: Bool { code == .fileNoSuchFile || code == .fileReadNoSuchFile }

    // FileHandle can report fileWriteNoPermission when opening a file for reading.
    var isUnavailableFile: Bool { isMissingFile || code == .fileReadNoPermission || code == .fileWriteNoPermission }
}
