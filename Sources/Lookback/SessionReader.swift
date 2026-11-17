import Foundation

/// Identifies a session within its source. Different providers can use the same native ID.
public struct SessionID: Hashable, Sendable {
    public let source: String
    public let value: String

    public init(source: String, value: String) {
        self.source = source
        self.value = value
    }
}

public struct SessionInfo: Identifiable, Sendable {
    public let id: SessionID
    public let title: String
    public let workingDirectory: String?
    public let gitBranch: String?
    public let createdAt: Date?
    public let modifiedAt: Date

    public init(id: SessionID, title: String, workingDirectory: String?, gitBranch: String?,
                createdAt: Date?, modifiedAt: Date) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.gitBranch = gitBranch
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

public enum MessageRole: Sendable {
    case user, assistant, tool, system
}

public enum MessageBlock: Equatable, Sendable {
    case text(String)
    /// A UTF-8 JSON value, including an object, array, string, or null.
    case toolCall(id: String, name: String, inputJSON: Data?)
    case toolResult(callID: String, contentJSON: Data?, isError: Bool)
    /// Keeps the position and source type of blocks without a portable representation.
    case other(type: String)
}

public struct SessionMessage: Identifiable, Sendable {
    public let id: String
    public let parentID: String?
    public let timestamp: Date?
    public let role: MessageRole
    public let blocks: [MessageBlock]
    public let isCompactionSummary: Bool

    public init(id: String, parentID: String?, timestamp: Date?, role: MessageRole,
                blocks: [MessageBlock], isCompactionSummary: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.timestamp = timestamp
        self.role = role
        self.blocks = blocks
        self.isCompactionSummary = isCompactionSummary
    }
}

public struct SessionHistory: Sendable {
    public let id: SessionID
    /// The conversation on the selected branch, including linked tool activity.
    public let conversation: [SessionMessage]
    /// Visible messages in storage order, including superseded branches and earlier context.
    public let recordedMessages: [SessionMessage]

    public init(id: SessionID, conversation: [SessionMessage], recordedMessages: [SessionMessage]) {
        self.id = id
        self.conversation = conversation
        self.recordedMessages = recordedMessages
    }
}

public protocol SessionReader: Sendable {
    var source: String { get }
    func listSessions() throws -> [SessionInfo]
    func readSession(_ id: SessionID) throws -> SessionHistory
}

public enum SessionReadError: Error, Equatable {
    case unsupportedSource(String)
    case invalidSessionID(String)
    case sessionNotFound(SessionID)
}
