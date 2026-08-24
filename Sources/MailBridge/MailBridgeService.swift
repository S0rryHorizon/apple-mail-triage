import Foundation
import MailBridgeCore

final class MailBridgeService {
  private let automation: MailAutomation
  private let store: StateStore

  init() throws {
    automation = MailAutomation()
    store = try StateStore()
  }

  func handle(_ request: BridgeRequest) throws -> BridgeResponse {
    switch request.action {
    case "setup": return try status(request, setup: true)
    case "status": return try status(request, setup: false)
    case "message.scan": return try scan(request)
    case "message.read": return try read(request)
    case "attachment.export": return try exportAttachment(request)
    case "attachment.cleanup": return try cleanupAttachment(request)
    case "flag.preview": return try previewFlags(request)
    case "flag.commit": return try commitFlags(request)
    case "flag.rollback": return try rollbackFlags(request)
    case "state.status": return try stateStatus(request)
    case "state.record": return try recordState(request)
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
    let since: Date
    if let value = request.since {
      guard let parsed = DateCodec.date(value) else {
        throw MailBridgeError.invalidRequest("since 必须是 ISO 8601 时间。")
      }
      since = parsed
    } else if let earliest = state.cursors.compactMap({ DateCodec.date($0.receivedAt) }).min() {
      since = earliest.addingTimeInterval(-15 * 60)
    } else {
      since = Date().addingTimeInterval(-24 * 60 * 60)
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
    let preview = min(max(request.previewCharacters ?? 800, 0), 4_000)
    let scanned = try automation.scan(
      since: since,
      until: until,
      offset: offset,
      limit: limit + 1,
      previewCharacters: preview
    )
    let hasMore = scanned.count > limit
    let page = Array(scanned.prefix(limit))
    var messages: [MailMessage] = []
    var seenFingerprints = Set<String>()
    for message in page {
      if seenFingerprints.insert(message.fingerprint).inserted,
        try !store.isProcessed(message.ref, fingerprint: message.fingerprint)
      {
        messages.append(message)
      }
    }
    var response = BridgeResponse(ok: true, status: "ok", requestId: request.requestId)
    response.messages = messages
    response.state = state
    response.details = [
      "since": DateCodec.string(since),
      "until": DateCodec.string(until),
      "offset": String(offset),
      "nextOffset": String(offset + page.count),
      "hasMore": hasMore ? "true" : "false",
      "scannedCount": String(page.count),
      "newCount": String(messages.count),
      "overlapMinutes": "15",
    ]
    return response
  }

  private func read(_ request: BridgeRequest) throws -> BridgeResponse {
    guard let ref = request.ref else { throw MailBridgeError.invalidRequest("message.read 缺少 ref。") }
    let limit = min(max(request.maxBodyCharacters ?? 8_000, 0), 40_000)
    let message = try automation.read(ref: ref, maxCharacters: limit)
    var response = BridgeResponse(ok: true, status: "ok", requestId: request.requestId)
    response.messages = [message]
    return response
  }

  private func exportAttachment(_ request: BridgeRequest) throws -> BridgeResponse {
    guard let ref = request.ref, let attachmentId = request.attachmentId else {
      throw MailBridgeError.invalidRequest("attachment.export 需要 ref 和 attachmentId。")
    }
    let message = try automation.read(ref: ref, maxCharacters: 0)
    let attachments = message.attachments ?? []
    guard attachments.reduce(Int64(0), { $0 + max($1.size, 0) }) <= 20 * 1024 * 1024 else {
      throw MailBridgeError.attachmentRejected("该邮件附件合计超过 20 MB。")
    }
    guard let attachment = attachments.first(where: { $0.id == attachmentId }) else {
      throw MailBridgeError.notFound("找不到指定附件。")
    }
    guard TriageRules.attachmentAllowed(
      name: attachment.name, mimeType: attachment.mimeType, size: attachment.size
    ) else {
      throw MailBridgeError.attachmentRejected("附件类型或大小不在安全白名单内：\(attachment.name)")
    }
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("MailTriage", isDirectory: true)
      .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let fileName = sanitizedFileName(attachment.name)
    let output = base.appendingPathComponent(fileName)
    try automation.exportAttachment(ref: ref, attachmentId: attachmentId, destination: output.path)
    let token = try store.registerExport(path: base.path)
    var response = BridgeResponse(ok: true, status: "exported", requestId: request.requestId)
    response.attachment = ExportedAttachment(
      path: output.path,
      cleanupToken: token,
      name: attachment.name,
      mimeType: attachment.mimeType,
      size: attachment.size
    )
    return response
  }

  private func cleanupAttachment(_ request: BridgeRequest) throws -> BridgeResponse {
    guard let token = request.cleanupToken else {
      throw MailBridgeError.invalidRequest("attachment.cleanup 缺少 cleanupToken。")
    }
    let path = try store.exportPath(token: token)
    let expected = FileManager.default.temporaryDirectory.appendingPathComponent("MailTriage").standardizedFileURL.path
    let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
    guard resolved.hasPrefix(expected + "/") else {
      throw MailBridgeError.attachmentRejected("拒绝清理 MailTriage 临时目录以外的路径。")
    }
    if FileManager.default.fileExists(atPath: resolved) {
      try FileManager.default.removeItem(atPath: resolved)
    }
    try store.removeExport(token: token)
    return BridgeResponse(ok: true, status: "cleaned", requestId: request.requestId)
  }

  private func previewFlags(_ request: BridgeRequest) throws -> BridgeResponse {
    guard let instructions = request.flags, !instructions.isEmpty else {
      throw MailBridgeError.invalidRequest("flag.preview 需要非空 flags。")
    }
    var results: [FlagResult] = []
    for instruction in instructions {
      do {
        let desired = try TriageRules.flagIndex(for: instruction.color)
        let previous = try automation.flagIndex(ref: instruction.ref)
        results.append(
          FlagResult(
            ref: instruction.ref,
            requestedColor: instruction.color,
            previousFlagIndex: previous,
            resultingFlagIndex: previous == -1 ? desired : previous,
            status: previous == -1 ? "would_flag" : "preserved_existing",
            message: previous == -1 ? nil : "邮件已有旗标，不会覆盖。"
          ))
      } catch {
        results.append(
          FlagResult(
            ref: instruction.ref,
            requestedColor: instruction.color,
            previousFlagIndex: -1,
            resultingFlagIndex: -1,
            status: "error",
            message: String(describing: error)
          ))
      }
    }
    var response = BridgeResponse(ok: true, status: "preview", requestId: request.requestId)
    response.flags = results
    response.state = try store.summary()
    return response
  }

  private func commitFlags(_ request: BridgeRequest) throws -> BridgeResponse {
    guard request.confirmed == true else {
      throw MailBridgeError.confirmationRequired("flag.commit 需要 confirmed: true。")
    }
    let state = try store.summary()
    guard state.flaggingEnabled else {
      throw MailBridgeError.confirmationRequired("真实旗标尚未启用；请继续使用 flag.preview 完成影子运行。")
    }
    guard let instructions = request.flags, !instructions.isEmpty else {
      throw MailBridgeError.invalidRequest("flag.commit 需要非空 flags。")
    }
    let batchId = request.batchId ?? UUID().uuidString.lowercased()
    try store.beginFlagBatch(batchId)
    var results: [FlagResult] = []
    for instruction in instructions {
      do {
        let desired = try TriageRules.flagIndex(for: instruction.color)
        let previous = try automation.flagIndex(ref: instruction.ref)
        if previous != -1 {
          results.append(
            FlagResult(
              ref: instruction.ref,
              requestedColor: instruction.color,
              previousFlagIndex: previous,
              resultingFlagIndex: previous,
              status: "preserved_existing",
              message: "邮件已有旗标，不会覆盖。"
            ))
          continue
        }
        let resulting = try automation.setFlagIndex(ref: instruction.ref, value: desired)
        let operation = FlagAuditOperation(
          ref: instruction.ref,
          previousFlagIndex: previous,
          resultingFlagIndex: resulting,
          requestedColor: instruction.color
        )
        try store.recordFlag(batchId: batchId, operation: operation)
        results.append(
          FlagResult(
            ref: instruction.ref,
            requestedColor: instruction.color,
            previousFlagIndex: previous,
            resultingFlagIndex: resulting,
            status: "flagged",
            message: nil
          ))
      } catch {
        results.append(
          FlagResult(
            ref: instruction.ref,
            requestedColor: instruction.color,
            previousFlagIndex: -1,
            resultingFlagIndex: -1,
            status: "error",
            message: String(describing: error)
          ))
      }
    }
    var response = BridgeResponse(ok: true, status: "committed", requestId: request.requestId)
    response.batchId = batchId
    response.flags = results
    return response
  }

  private func rollbackFlags(_ request: BridgeRequest) throws -> BridgeResponse {
    guard request.confirmed == true, let batchId = request.batchId else {
      throw MailBridgeError.confirmationRequired("flag.rollback 需要 batchId 和 confirmed: true。")
    }
    let operations = try store.flagOperations(batchId: batchId)
    guard !operations.isEmpty else { throw MailBridgeError.notFound("该批次没有可回滚的旗标。") }
    var results: [FlagResult] = []
    var failed = false
    for operation in operations {
      do {
        let current = try automation.flagIndex(ref: operation.ref)
        if current != operation.resultingFlagIndex {
          results.append(
            FlagResult(
              ref: operation.ref,
              requestedColor: operation.requestedColor,
              previousFlagIndex: current,
              resultingFlagIndex: current,
              status: "preserved_user_change",
              message: "当前旗标已变化，不覆盖用户后续修改。"
            ))
          continue
        }
        let resulting = try automation.setFlagIndex(ref: operation.ref, value: operation.previousFlagIndex)
        results.append(
          FlagResult(
            ref: operation.ref,
            requestedColor: operation.requestedColor,
            previousFlagIndex: current,
            resultingFlagIndex: resulting,
            status: "rolled_back",
            message: nil
          ))
      } catch {
        failed = true
        results.append(
          FlagResult(
            ref: operation.ref,
            requestedColor: operation.requestedColor,
            previousFlagIndex: -1,
            resultingFlagIndex: -1,
            status: "error",
            message: String(describing: error)
          ))
      }
    }
    if !failed { try store.markFlagBatchRolledBack(batchId) }
    var response = BridgeResponse(
      ok: !failed,
      status: failed ? "partial_error" : "rolled_back",
      requestId: request.requestId
    )
    response.batchId = batchId
    response.flags = results
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
    if update.flaggingEnabled == true && request.confirmed != true {
      throw MailBridgeError.confirmationRequired("启用真实旗标需要 confirmed: true。")
    }
    try store.record(update)
    var response = BridgeResponse(ok: true, status: "recorded", requestId: request.requestId)
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
