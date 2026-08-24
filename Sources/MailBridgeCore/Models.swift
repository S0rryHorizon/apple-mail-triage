import Foundation

public enum MailBridgeError: Error, CustomStringConvertible {
  case invalidRequest(String)
  case permissionDenied(String)
  case mailAutomation(String)
  case notFound(String)
  case confirmationRequired(String)
  case attachmentRejected(String)
  case storage(String)

  public var description: String {
    switch self {
    case .invalidRequest(let message), .permissionDenied(let message),
      .mailAutomation(let message), .notFound(let message),
      .confirmationRequired(let message), .attachmentRejected(let message),
      .storage(let message): return message
    }
  }
}

public enum TriageCategory: String, Codable, CaseIterable, Sendable {
  case action
  case schedule
  case risk
  case information
  case noise
}

public enum CandidateKind: String, Codable, Sendable {
  case event
  case reminder
}

public struct MessageRef: Codable, Hashable, Sendable {
  public var accountId: String
  public var libraryId: Int64
  public var messageId: String?

  public init(accountId: String, libraryId: Int64, messageId: String? = nil) {
    self.accountId = accountId
    self.libraryId = libraryId
    self.messageId = messageId
  }
}

public struct MailAccount: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var enabled: Bool

  public init(id: String, name: String, enabled: Bool) {
    self.id = id
    self.name = name
    self.enabled = enabled
  }
}

public struct AttachmentInfo: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var mimeType: String
  public var size: Int64
  public var downloaded: Bool

  public init(id: String, name: String, mimeType: String, size: Int64, downloaded: Bool) {
    self.id = id
    self.name = name
    self.mimeType = mimeType
    self.size = size
    self.downloaded = downloaded
  }
}

public struct MailMessage: Codable, Equatable, Sendable {
  public var ref: MessageRef
  public var accountName: String
  public var mailboxName: String
  public var receivedAt: String
  public var sender: String
  public var subject: String
  public var sanitizedText: String?
  public var isRead: Bool
  public var flagIndex: Int
  public var attachmentCount: Int
  public var attachments: [AttachmentInfo]?
  public var fingerprint: String
  public var hint: TriageCategory

  public init(
    ref: MessageRef,
    accountName: String,
    mailboxName: String,
    receivedAt: String,
    sender: String,
    subject: String,
    sanitizedText: String?,
    isRead: Bool,
    flagIndex: Int,
    attachmentCount: Int,
    attachments: [AttachmentInfo]?,
    fingerprint: String,
    hint: TriageCategory
  ) {
    self.ref = ref
    self.accountName = accountName
    self.mailboxName = mailboxName
    self.receivedAt = receivedAt
    self.sender = sender
    self.subject = subject
    self.sanitizedText = sanitizedText
    self.isRead = isRead
    self.flagIndex = flagIndex
    self.attachmentCount = attachmentCount
    self.attachments = attachments
    self.fingerprint = fingerprint
    self.hint = hint
  }
}

public struct FlagInstruction: Codable, Sendable {
  public var ref: MessageRef
  public var color: String
}

public struct FlagResult: Codable, Equatable, Sendable {
  public var ref: MessageRef
  public var requestedColor: String
  public var previousFlagIndex: Int
  public var resultingFlagIndex: Int
  public var status: String
  public var message: String?

  public init(
    ref: MessageRef,
    requestedColor: String,
    previousFlagIndex: Int,
    resultingFlagIndex: Int,
    status: String,
    message: String?
  ) {
    self.ref = ref
    self.requestedColor = requestedColor
    self.previousFlagIndex = previousFlagIndex
    self.resultingFlagIndex = resultingFlagIndex
    self.status = status
    self.message = message
  }
}

public struct CandidateRecord: Codable, Equatable, Sendable {
  public var id: String
  public var kind: CandidateKind
  public var title: String
  public var start: String?
  public var end: String?
  public var due: String?
  public var location: String?
  public var notes: String?
  public var accountId: String
  public var libraryId: Int64
  public var sourceSubject: String
  public var status: String?

  public init(
    id: String,
    kind: CandidateKind,
    title: String,
    start: String? = nil,
    end: String? = nil,
    due: String? = nil,
    location: String? = nil,
    notes: String? = nil,
    accountId: String,
    libraryId: Int64,
    sourceSubject: String,
    status: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.start = start
    self.end = end
    self.due = due
    self.location = location
    self.notes = notes
    self.accountId = accountId
    self.libraryId = libraryId
    self.sourceSubject = sourceSubject
    self.status = status
  }
}

public struct ProcessedRecord: Codable, Sendable {
  public var ref: MessageRef
  public var fingerprint: String
  public var receivedAt: String
  public var category: TriageCategory
  public var candidateId: String?
}

public struct CursorRecord: Codable, Equatable, Sendable {
  public var accountId: String
  public var receivedAt: String

  public init(accountId: String, receivedAt: String) {
    self.accountId = accountId
    self.receivedAt = receivedAt
  }
}

public struct ExplicitRule: Codable, Equatable, Sendable {
  public var id: String?
  public var field: String
  public var pattern: String
  public var category: TriageCategory
  public var enabled: Bool?

  public init(
    id: String? = nil,
    field: String,
    pattern: String,
    category: TriageCategory,
    enabled: Bool? = nil
  ) {
    self.id = id
    self.field = field
    self.pattern = pattern
    self.category = category
    self.enabled = enabled
  }
}

public struct StateUpdate: Codable, Sendable {
  public var processed: [ProcessedRecord]?
  public var candidates: [CandidateRecord]?
  public var cursors: [CursorRecord]?
  public var shadowRunsCompleted: Int?
  public var flaggingEnabled: Bool?
}

public struct BridgeRequest: Codable, Sendable {
  public var action: String
  public var requestId: String?
  public var since: String?
  public var until: String?
  public var offset: Int?
  public var limit: Int?
  public var previewCharacters: Int?
  public var maxBodyCharacters: Int?
  public var ref: MessageRef?
  public var attachmentId: String?
  public var cleanupToken: String?
  public var confirmed: Bool?
  public var batchId: String?
  public var flags: [FlagInstruction]?
  public var state: StateUpdate?
  public var candidateIds: [String]?
  public var candidateStatus: String?
  public var rule: ExplicitRule?

  public init(action: String) { self.action = action }
}

public struct StateSummary: Codable, Equatable, Sendable {
  public var processedCount: Int
  public var pendingCandidateCount: Int
  public var cursors: [CursorRecord]
  public var shadowRunsCompleted: Int
  public var flaggingEnabled: Bool

  public init(
    processedCount: Int,
    pendingCandidateCount: Int,
    cursors: [CursorRecord],
    shadowRunsCompleted: Int,
    flaggingEnabled: Bool
  ) {
    self.processedCount = processedCount
    self.pendingCandidateCount = pendingCandidateCount
    self.cursors = cursors
    self.shadowRunsCompleted = shadowRunsCompleted
    self.flaggingEnabled = flaggingEnabled
  }
}

public struct ExportedAttachment: Codable, Equatable, Sendable {
  public var path: String
  public var cleanupToken: String
  public var name: String
  public var mimeType: String
  public var size: Int64

  public init(path: String, cleanupToken: String, name: String, mimeType: String, size: Int64) {
    self.path = path
    self.cleanupToken = cleanupToken
    self.name = name
    self.mimeType = mimeType
    self.size = size
  }
}

public struct BridgeResponse: Codable, Sendable {
  public var ok: Bool
  public var status: String
  public var requestId: String?
  public var message: String?
  public var batchId: String?
  public var details: [String: String]?
  public var accounts: [MailAccount]?
  public var messages: [MailMessage]?
  public var flags: [FlagResult]?
  public var candidates: [CandidateRecord]?
  public var rules: [ExplicitRule]?
  public var state: StateSummary?
  public var attachment: ExportedAttachment?
  public var errors: [String]?

  public init(
    ok: Bool,
    status: String,
    requestId: String? = nil,
    message: String? = nil
  ) {
    self.ok = ok
    self.status = status
    self.requestId = requestId
    self.message = message
  }
}

public enum DateCodec {
  private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = fractional
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter
  }

  public static func string(_ date: Date) -> String { formatter(fractional: true).string(from: date) }

  public static func date(_ value: String) -> Date? {
    if let date = formatter(fractional: true).date(from: value) { return date }
    return formatter(fractional: false).date(from: value)
  }
}
