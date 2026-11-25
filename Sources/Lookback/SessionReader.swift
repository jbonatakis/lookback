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

/// Metadata for a provider-generated background task update. The original payload remains in the message blocks.
public struct SessionTaskNotification: Codable, Equatable, Sendable {
    public let taskID, toolUseID, status, summary, result: String?

    public init(taskID: String? = nil, toolUseID: String? = nil, status: String? = nil,
                summary: String? = nil, result: String? = nil) {
        self.taskID = taskID
        self.toolUseID = toolUseID
        self.status = status
        self.summary = summary
        self.result = result
    }
}

/// A provider-reported completion. A matching ID describes the model call itself. A different
/// ID records an event observed while a single script was in flight, without claiming causality.
public struct SessionToolEvent: Sendable {
    public let id, name: String
    public let inputJSON, outputJSON: Data?
    public let exitCode: Int?
    public let isError: Bool
}

public struct SessionMessage: Identifiable, Sendable {
    /// The source's message ID. Multiple recorded occurrences can share this value.
    public let id: String
    /// Zero-based position in this history's recordedMessages, when supplied by the provider.
    public let recordedIndex: Int?
    public let parentID: String?
    public let timestamp: Date?
    public let role: MessageRole
    public internal(set) var blocks: [MessageBlock]
    public internal(set) var toolEvents: [SessionToolEvent]
    public let taskNotification: SessionTaskNotification?
    public let isCompactionSummary: Bool

    public init(id: String, parentID: String?, timestamp: Date?, role: MessageRole,
                blocks: [MessageBlock], isCompactionSummary: Bool = false, recordedIndex: Int? = nil,
                taskNotification: SessionTaskNotification? = nil, toolEvents: [SessionToolEvent] = []) {
        self.id = id
        self.recordedIndex = recordedIndex
        self.parentID = parentID
        self.timestamp = timestamp
        self.role = role
        self.blocks = blocks
        self.toolEvents = toolEvents
        self.taskNotification = taskNotification
        self.isCompactionSummary = isCompactionSummary
    }
}

public struct SessionHistory: Sendable {
    public let id: SessionID
    /// Session metadata, when available from the provider during the read.
    public let info: SessionInfo?
    /// The conversation on the selected branch, including linked tool activity.
    public let conversation: [SessionMessage]
    /// The selected branch's visible exchange. Codex retains original turns across context compaction.
    public let transcript: [SessionMessage]
    /// Visible messages in storage order, including superseded branches and earlier context.
    public let recordedMessages: [SessionMessage]

    public init(id: SessionID, conversation: [SessionMessage], recordedMessages: [SessionMessage], info: SessionInfo? = nil,
                transcript: [SessionMessage]? = nil) {
        self.id = id
        self.info = info
        self.conversation = conversation
        self.transcript = transcript ?? conversation
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
    /// A persisted thread refers to a missing, inaccessible, or inconsistent history segment.
    case incompleteHistory(SessionID)
}
