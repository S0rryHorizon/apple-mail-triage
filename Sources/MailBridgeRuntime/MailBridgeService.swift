import Foundation
import MailBridgeCore

public final class MailBridgeService {
  private let automation: MailAutomation
  private let store: StateStore
  private let accountProvider: () throws -> [MailAccount]
  private let scanProvider: (Date, Date, Int, Int, Int) throws -> [MailMessage]

  public init() throws {
    let mail = MailAutomation()
    automation = mail
    store = try StateStore()
    try TemporaryAttachments.sweep(store: store)
    accountProvider = { try mail.accounts() }
    scanProvider = { since, until, offset, limit, _ in
      try mail.scanMetadata(since: since, until: until, offset: offset, limit: limit)
    }
  }

  package init(
    store: StateStore,
    accountProvider: @escaping () throws -> [MailAccount],
    scanProvider: ((Date, Date, Int, Int, Int) throws -> [MailMessage])? = nil
  ) {
    let mail = MailAutomation()
    automation = mail
    self.store = store
    self.accountProvider = accountProvider
    self.scanProvider = scanProvider ?? { since, until, offset, limit, _ in
      try mail.scanMetadata(since: since, until: until, offset: offset, limit: limit)
    }
  }

  init(automation: MailAutomation, store: StateStore) {
    self.automation = automation
    self.store = store
    self.accountProvider = { try automation.accounts() }
    self.scanProvider = { since, until, offset, limit, _ in
      try automation.scanMetadata(since: since, until: until, offset: offset, limit: limit)
    }
  }

  public func handle(_ request: BridgeRequest) throws -> BridgeResponse {
    switch request.action {
    case "setup": return try status(request, setup: true)
    case "status": return try status(request, setup: false)
    case "message.scan": return try automation.withReadDeadline { try scan(request) }
    case "message.read": return try read(request)
    case "attachment.export": return try exportAttachment(request)
    case "attachment.text": return try attachmentText(request)
    case "attachment.cleanup": return try cleanupAttachment(request)
    case "state.status": return try stateStatus(request)
    case "state.record": return try recordState(request)
    case "state.repair": return try repairState(request)
    case "state.pending": return try pendingCandidates(request)
    case "candidate.resolve": return try resolveCandidates(request)
    case "rule.list": return try listRules(request)
    case "rule.upsert": return try upsertRule(request)
    default: throw MailBridgeError.invalidRequest("未知 action：\(request.action)")
    }
  }

  private func status(_ request: BridgeRequest, setup: Bool) throws -> BridgeResponse {
    let accounts = try automation.accounts()
    var response = BridgeResponse(
      ok: true,
      status: "ok",
      requestId: request.requestId,
      message: setup ? "Apple“邮件”自动化权限正常。" : nil
    )
    response.accounts = accounts
    response.state = try store.summary()
    response.details = [
      "mailAccess": "authorized",
      "accountCount": String(accounts.filter(\.enabled).count),
      "timezone": "Asia/Singapore",
    ]
    return response
  }

  private func scan(_ request: BridgeRequest) throws -> BridgeResponse {
    let state = try store.summary()
    let enabledAccountIds = Set(try accountProvider().filter(\.enabled).map(\.id))
    let since: Date
    if let value = request.since {
      guard let parsed = DateCodec.date(value) else {
        throw MailBridgeError.invalidRequest("since 必须是 ISO 8601 时间。")
      }
      since = parsed
    } else {
      let firstRunSince = Date().addingTimeInterval(-24 * 60 * 60)
      let cursors = Dictionary(uniqueKeysWithValues: state.cursors.map { ($0.accountId, $0.receivedAt) })
      since = enabledAccountIds.map { accountId in
        cursors[accountId].flatMap(DateCodec.date)?.addingTimeInterval(-15 * 60) ?? firstRunSince
      }.min() ?? firstRunSince
    }
    let until: Date
    if let value = request.until {
      guard let parsed = DateCodec.date(value) else {
        throw MailBridgeError.invalidRequest("until 必须是 ISO 8601 时间。")
      }
      until = parsed
    } else {
      until = Date()
    }
    guard until >= since else {
      throw MailBridgeError.invalidRequest("until 不得早于 since。")
    }
    let offset = max(request.offset ?? 0, 0)
    let limit = min(max(request.limit ?? 200, 1), 1_000)
    guard offset <= Int.max - limit else {
      throw MailBridgeError.invalidRequest("offset 过大。")
    }
    let preview = min(max(request.previewCharacters ?? 800, 0), 4_000)
    let scanned = try scanProvider(since, until, offset, limit + 1, 0)
    let hasMore = scanned.count > limit
    let page = Array(scanned.prefix(limit))
    var messages: [MailMessage] = []
    var seenFingerprints = Set<String>()
    for var message in page {
      if enabledAccountIds.contains(message.ref.accountId),
        seenFingerprints.insert(message.fingerprint).inserted,
        try !store.isProcessed(message.ref, fingerprint: message.fingerprint)
      {
        do {
          let text = try automation.preview(ref: message.ref, maxCharacters: preview)
          message.sanitizedText = text
          message.hint = TriageRules.hint(sender: message.sender, subject: message.subject, text: text)
          if preview > 0 { try store.clearBodyFailure(message.ref) }
          else if try store.hasBodyFailure(message.ref) { message.bodyReadError = "body_not_read" }
        } catch MailBridgeError.bodyUnavailable(let reason) {
          message.bodyReadError = reason
          try store.bodyFailure(message, reason: reason)
        }
        messages.append(message)
      }
    }
    var response = BridgeResponse(ok: true, status: "ok", requestId: request.requestId)
    if messages.contains(where: { $0.bodyReadError != nil }) { response.status = "partial" }
    response.messages = messages.sorted {
      if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
      if $0.ref.accountId != $1.ref.accountId { return $0.ref.accountId < $1.ref.accountId }
      return $0.ref.libraryId < $1.ref.libraryId
    }
    response.rules = try store.rules()
    response.state = try store.summary()
    response.details = [
      "since": DateCodec.string(since),
      "until": DateCodec.string(until),
      "offset": String(offset),
      "nextOffset": String(offset + page.count),
      "hasMore": hasMore ? "true" : "false",
      "scannedCount": String(page.count),
      "newCount": String(messages.count),
      "overlapMinutes": "15",
      "bodyFailureCount": String(messages.filter { $0.bodyReadError != nil }.count),
    ]
    return response
  }

  private func read(_ request: BridgeRequest) throws -> BridgeResponse {
    guard let ref = request.ref else { throw MailBridgeError.invalidRequest("message.read 缺少 ref。") }
    let limit = min(max(request.maxBodyCharacters ?? 8_000, 0), 40_000)
    var message: MailMessage
    do {
      message = try automation.read(ref: ref, maxCharacters: limit)
      if limit > 0 { try store.clearBodyFailure(ref) }
      else if try store.hasBodyFailure(ref) { message.bodyReadError = "body_not_read" }
    } catch MailBridgeError.bodyUnavailable(let reason) {
      message = try automation.read(ref: ref, maxCharacters: 0)
      message.bodyReadError = reason
      if try !store.isProcessed(ref, fingerprint: message.fingerprint) {
        try store.bodyFailure(message, reason: reason)
      }
    }
    var response = BridgeResponse(ok: true, status: "ok", requestId: request.requestId)
    if message.bodyReadError != nil { response.status = "partial" }
    response.messages = [message]
    return response
  }

  private func exportAttachment(_ request: BridgeRequest) throws -> BridgeResponse {
    guard let ref = request.ref, let attachmentId = request.attachmentId else {
      throw MailBridgeError.invalidRequest("attachment.export 需要 ref 和 attachmentId。")
    }
    let message = try automation.read(ref: ref, maxCharacters: 0)
    let attachments = message.attachments ?? []
    if let reason = TriageRules.attachmentTotalRejection(sizes: attachments.map(\.size)) {
      throw MailBridgeError.attachmentRejected("\(reason.rawValue): \(reason.message)")
    }
    guard let attachment = attachments.first(where: { $0.id == attachmentId }) else {
      throw MailBridgeError.notFound("找不到指定附件。")
    }
    let mime: String
    let inferred: Bool
    switch TriageRules.attachmentDecision(name: attachment.name, mimeType: attachment.mimeType, size: attachment.size) {
    case .allowed(let effective, let fallback): mime = effective; inferred = fallback
    case .rejected(let reason):
      throw MailBridgeError.attachmentRejected("\(reason.rawValue): \(reason.message)")
    }
    let base = TemporaryAttachments.root
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let fileName = sanitizedFileName(attachment.name)
    let output = base.appendingPathComponent(fileName)
    let token: String
    do {
      token = try store.registerExport(path: base.path)
      do {
        try automation.exportAttachment(ref: ref, attachmentId: attachmentId, destination: output.path)
      } catch {
        try TemporaryAttachments.remove(base.path)
        try store.removeExport(token: token)
        throw error
      }
    } catch {
      try? FileManager.default.removeItem(at: base)
      throw error
    }
    var response = BridgeResponse(ok: true, status: "exported", requestId: request.requestId)
    response.details = ["mimeInferred": String(inferred), "mimeDiagnostic": inferred ? "MIME 为空，已根据安全扩展名推断。" : "MIME 与扩展名匹配。"]
    response.attachment = ExportedAttachment(
      path: output.path,
      cleanupToken: token,
      name: attachment.name,
      mimeType: mime,
      size: attachment.size
    )
    return response
  }

  private func cleanupAttachment(_ request: BridgeRequest) throws -> BridgeResponse {
    guard let token = request.cleanupToken else {
      throw MailBridgeError.invalidRequest("attachment.cleanup 缺少 cleanupToken。")
    }
    let path = try store.exportPath(token: token)
    try TemporaryAttachments.remove(path)
    try store.removeExport(token: token)
    return BridgeResponse(ok: true, status: "cleaned", requestId: request.requestId)
  }

  private func attachmentText(_ request: BridgeRequest) throws -> BridgeResponse {
    let exported = try exportAttachment(request).attachment!
    let conversion: Result<(String, Bool), Error>
    do {
      conversion = .success(try AttachmentText.extract(path: exported.path, limit: min(max(request.maxBodyCharacters ?? 16000, 1), 40000)))
    } catch { conversion = .failure(error) }
    // Clean before returning either text or the conversion error. No Markdown files.
    var cleanup = BridgeRequest(action: "attachment.cleanup")
    cleanup.cleanupToken = exported.cleanupToken
    _ = try cleanupAttachment(cleanup)
    let (text, truncated) = try conversion.get()
    var response = BridgeResponse(ok: true, status: "extracted", requestId: request.requestId)
    response.text = text
    response.details = ["cleanup": "cleaned", "truncated": String(truncated),
                        "contentScope": "text_only", "imagesAndLayoutVerified": "false"]
    return response
  }

  private func stateStatus(_ request: BridgeRequest) throws -> BridgeResponse {
    var response = BridgeResponse(ok: true, status: "ok", requestId: request.requestId)
    response.state = try store.summary()
    return response
  }

  private func recordState(_ request: BridgeRequest) throws -> BridgeResponse {
    guard let update = request.state else {
      throw MailBridgeError.invalidRequest("state.record 缺少 state。")
    }
    try store.record(update, enabledAccountIds: Set(try accountProvider().filter(\.enabled).map(\.id)))
    var response = BridgeResponse(ok: true, status: "recorded", requestId: request.requestId)
    response.state = try store.summary()
    return response
  }

  private func repairState(_ request: BridgeRequest) throws -> BridgeResponse {
    guard request.confirmed == true else {
      throw MailBridgeError.confirmationRequired("state.repair 需要 confirmed: true。")
    }
    guard let ids = request.accountIds, !ids.isEmpty else {
      throw MailBridgeError.invalidRequest("state.repair 需要非空 accountIds。")
    }
    // Disabled accounts still exist and their cursors must be preserved.
    try store.removeOrphanCursors(ids: ids, knownAccountIds: Set(try accountProvider().map(\.id)))
    var response = BridgeResponse(ok: true, status: "repaired", requestId: request.requestId)
    response.state = try store.summary()
    return response
  }

  private func pendingCandidates(_ request: BridgeRequest) throws -> BridgeResponse {
    var response = BridgeResponse(ok: true, status: "ok", requestId: request.requestId)
    response.candidates = try store.pendingCandidates()
    return response
  }

  private func resolveCandidates(_ request: BridgeRequest) throws -> BridgeResponse {
    guard request.confirmed == true,
      let ids = request.candidateIds, !ids.isEmpty,
      let status = request.candidateStatus
    else {
      throw MailBridgeError.confirmationRequired(
        "candidate.resolve 需要 candidateIds、candidateStatus 和 confirmed: true。")
    }
    try store.resolveCandidates(ids: ids, status: status)
    var response = BridgeResponse(ok: true, status: "resolved", requestId: request.requestId)
    response.candidates = try store.pendingCandidates()
    return response
  }

  private func listRules(_ request: BridgeRequest) throws -> BridgeResponse {
    var response = BridgeResponse(ok: true, status: "ok", requestId: request.requestId)
    response.rules = try store.rules()
    return response
  }

  private func upsertRule(_ request: BridgeRequest) throws -> BridgeResponse {
    guard request.confirmed == true, let rule = request.rule else {
      throw MailBridgeError.confirmationRequired(
        "只有用户明确要求长期规则时，rule.upsert 才可使用 confirmed: true。")
    }
    var response = BridgeResponse(ok: true, status: "recorded", requestId: request.requestId)
    response.rules = [try store.upsertRule(rule)]
    return response
  }

  private func sanitizedFileName(_ value: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:\u{0000}")
    let pieces = value.components(separatedBy: invalid).filter { !$0.isEmpty }
    let joined = pieces.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
    return joined.isEmpty ? "attachment" : String(joined.prefix(180))
  }
}
