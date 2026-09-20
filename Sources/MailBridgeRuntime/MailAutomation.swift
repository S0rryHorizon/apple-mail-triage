@preconcurrency import AppKit
import Foundation
import MailBridgeCore

final class MailAutomation {
  private let executor: ((String) throws -> NSAppleEventDescriptor)?
  private let now: () -> Date
  private var readDeadline: Date?

  init(executor: ((String) throws -> NSAppleEventDescriptor)? = nil, now: @escaping () -> Date = Date.init) {
    self.executor = executor
    self.now = now
  }

  func withReadDeadline<T>(_ body: () throws -> T) rethrows -> T {
    let previous = readDeadline
    readDeadline = now().addingTimeInterval(60)
    defer { readDeadline = previous }
    return try body()
  }

  func accounts() throws -> [MailAccount] {
    let descriptor = try run(
      """
      tell application "Mail"
        set output to {}
        repeat with acct in every account
          set end of output to {(id of acct as text), (name of acct as text), (enabled of acct as boolean)}
        end repeat
        return output
      end tell
      """)
    guard descriptor.descriptorType == typeAEList else {
      throw MailBridgeError.mailAutomation("账户列表不完整；无法确认扫描范围。")
    }
    var accounts: [MailAccount] = []
    for index in 0..<descriptor.numberOfItems {
      guard let item = descriptor.atIndex(index + 1), item.numberOfItems == 3, !item.string(at: 1).isEmpty else {
        throw MailBridgeError.mailAutomation("账户元数据不完整；无法确认扫描范围。")
      }
      accounts.append(MailAccount(id: item.string(at: 1), name: item.string(at: 2), enabled: item.bool(at: 3)))
    }
    return accounts
  }

  func scanMetadata(
    since: Date,
    until: Date,
    offset: Int,
    limit: Int
  ) throws -> [MailMessage] {
    let safeOffset = max(offset, 0)
    let safeLimit = min(max(limit, 1), 1_001)
    let descriptor = try run(
      """
      tell application "Mail"
        \(dateScript(since, name: "cutoffDate", rounding: .up))
        \(dateScript(until, name: "upperDate", rounding: .down))
        set output to {}
        set candidates to every message of inbox whose date received is greater than or equal to cutoffDate and date received is less than or equal to upperDate
        set skipped to 0
        set emitted to 0
        repeat with msg in candidates
          \(readDeadline != nil ? "if (current date) is greater than bridgeDeadline then error \"scan_timeout\"" : "")
          if skipped is less than \(safeOffset) then
            set skipped to skipped + 1
          else
          if emitted is greater than or equal to \(safeLimit) then exit repeat
            set boxRef to mailbox of msg
            set acctRef to account of boxRef
            set rfcId to ""
            set rfcId to message id of msg
            if rfcId is missing value then set rfcId to ""
            set attachmentTotal to count of mail attachments of msg
            set end of output to {(id of acctRef as text), (name of acctRef as text), (name of boxRef as text), (id of msg as integer), rfcId, (date received of msg), (sender of msg as text), (subject of msg as text), (read status of msg as boolean), (flag index of msg as integer), attachmentTotal}
            set emitted to emitted + 1
          end if
        end repeat
        return output
      end tell
      """)
    guard descriptor.descriptorType == typeAEList else {
      throw MailBridgeError.mailAutomation("邮件列表不完整；本次扫描未完成，不能推进游标。")
    }
    var result: [MailMessage] = []
    for index in 0..<descriptor.numberOfItems {
      guard let item = descriptor.atIndex(index + 1), item.numberOfItems == 11 else {
        throw MailBridgeError.mailAutomation("邮件元数据不完整；本次扫描未完成，不能推进游标。")
      }
      let accountId = item.string(at: 1)
      let libraryId = item.int64(at: 4)
      guard !accountId.isEmpty, libraryId > 0, let receivedDate = item.at(6).dateValue else {
        throw MailBridgeError.mailAutomation("邮件元数据不完整；本次扫描未完成，不能推进游标。")
      }
      let messageId = item.optionalString(at: 5)
      let receivedAt = DateCodec.string(receivedDate)
      let sender = PrivacyFilter.sanitize(item.string(at: 7), limit: 500)
      let subject = PrivacyFilter.sanitize(item.string(at: 8), limit: 1_000)
      let ref = MessageRef(accountId: accountId, libraryId: libraryId, messageId: messageId)
      let fingerprint = PrivacyFilter.fingerprint(
        accountId: accountId,
        libraryId: libraryId,
        messageId: messageId,
        receivedAt: receivedAt,
        subject: subject
      )
      result.append(MailMessage(
        ref: ref,
        accountName: item.string(at: 2),
        mailboxName: item.string(at: 3),
        receivedAt: receivedAt,
        sender: sender,
        subject: subject,
        sanitizedText: "",
        isRead: item.bool(at: 9),
        flagIndex: item.int(at: 10),
        attachmentCount: item.int(at: 11),
        attachments: nil,
        fingerprint: fingerprint,
        hint: TriageRules.hint(sender: sender, subject: subject, text: "")
      ))
    }
    // Keep Mail's source order until the service removes the lookahead row.
    return result
  }

  func preview(ref: MessageRef, maxCharacters: Int) throws -> String {
    guard maxCharacters > 0 else { return "" }
    let descriptor = try run(findMessageScript(ref: ref, body: "return content of targetMessage as text"))
    guard let text = descriptor.stringValue else {
      throw MailBridgeError.mailAutomation("邮件正文未能读取；本次扫描未完成，不能推进游标。")
    }
    return PrivacyFilter.sanitize(text, limit: maxCharacters)
  }

  func read(ref: MessageRef, maxCharacters: Int) throws -> MailMessage {
    let descriptor = try run(findMessageScript(ref: ref, body: """
      set bodyText to ""
      \(maxCharacters > 0 ? "set bodyText to content of targetMessage as text" : "")
      set attachmentOutput to {}
      try
        repeat with att in mail attachments of targetMessage
          set attId to ""
          set attName to ""
          set attType to ""
          set attSize to 0
          set attDownloaded to false
          try
            set attId to id of att as text
          end try
          try
            set attName to name of att as text
          end try
          try
            set attType to MIME type of att as text
          end try
          try
            set attSize to file size of att as integer
          end try
          try
            set attDownloaded to downloaded of att as boolean
          end try
          set end of attachmentOutput to {attId, attName, attType, attSize, attDownloaded}
        end repeat
      end try
      set boxRef to mailbox of targetMessage
      set acctRef to account of boxRef
      set rfcId to ""
      try
        set rfcId to message id of targetMessage as text
      end try
      return {(id of acctRef as text), (name of acctRef as text), (name of boxRef as text), (id of targetMessage as integer), rfcId, (date received of targetMessage), (sender of targetMessage as text), (subject of targetMessage as text), (read status of targetMessage as boolean), (flag index of targetMessage as integer), attachmentOutput, bodyText}
      """))
    let accountId = descriptor.string(at: 1)
    let libraryId = descriptor.int64(at: 4)
    guard !accountId.isEmpty, libraryId > 0, let receivedDate = descriptor.at(6).dateValue else {
      throw MailBridgeError.notFound("找不到指定邮件。")
    }
    let messageId = descriptor.optionalString(at: 5)
    let receivedAt = DateCodec.string(receivedDate)
    let sender = PrivacyFilter.sanitize(descriptor.string(at: 7), limit: 500)
    let subject = PrivacyFilter.sanitize(descriptor.string(at: 8), limit: 1_000)
    let text = PrivacyFilter.sanitize(descriptor.string(at: 12), limit: maxCharacters)
    let attachments = descriptor.at(11).listItems.map { item in
      AttachmentInfo(
        id: item.string(at: 1),
        name: item.string(at: 2),
        mimeType: item.string(at: 3),
        size: item.int64(at: 4),
        downloaded: item.bool(at: 5)
      )
    }
    let resolvedRef = MessageRef(accountId: accountId, libraryId: libraryId, messageId: messageId)
    let fingerprint = PrivacyFilter.fingerprint(
      accountId: accountId,
      libraryId: libraryId,
      messageId: messageId,
      receivedAt: receivedAt,
      subject: subject
    )
    return MailMessage(
      ref: resolvedRef,
      accountName: descriptor.string(at: 2),
      mailboxName: descriptor.string(at: 3),
      receivedAt: receivedAt,
      sender: sender,
      subject: subject,
      sanitizedText: text,
      isRead: descriptor.bool(at: 9),
      flagIndex: descriptor.int(at: 10),
      attachmentCount: attachments.count,
      attachments: attachments,
      fingerprint: fingerprint,
      hint: TriageRules.hint(sender: sender, subject: subject, text: text)
    )
  }

  func flagIndex(ref: MessageRef) throws -> Int {
    let descriptor = try run(findMessageScript(ref: ref, body: "return flag index of targetMessage as integer"))
    return Int(descriptor.int32Value)
  }

  func setFlagIndex(ref: MessageRef, value: Int) throws -> Int {
    let descriptor = try run(findMessageScript(ref: ref, body: """
      set flag index of targetMessage to \(value)
      return flag index of targetMessage as integer
      """))
    return Int(descriptor.int32Value)
  }

  func exportAttachment(ref: MessageRef, attachmentId: String, destination: String) throws {
    let attachmentLiteral = appleScriptLiteral(attachmentId)
    let pathLiteral = appleScriptLiteral(destination)
    _ = try run(findMessageScript(ref: ref, body: """
      set matchingAttachments to every mail attachment of targetMessage whose id is \(attachmentLiteral)
      if (count of matchingAttachments) is 0 then error "attachment_not_found"
      set targetAttachment to item 1 of matchingAttachments
      save targetAttachment in POSIX file \(pathLiteral)
      return \(pathLiteral)
      """))
  }

  private func findMessageScript(ref: MessageRef, body: String) -> String {
    let accountLiteral = appleScriptLiteral(ref.accountId)
    return """
      tell application "Mail"
        set targetMessage to missing value
        set candidates to every message of inbox whose id is \(ref.libraryId)
        repeat with msg in candidates
          try
            set acctRef to account of mailbox of msg
            if (id of acctRef as text) is \(accountLiteral) then
              set targetMessage to msg
              exit repeat
            end if
          end try
        end repeat
        if targetMessage is missing value then error "message_not_found"
        \(body)
      end tell
      """
  }

  private func run(_ source: String) throws -> NSAppleEventDescriptor {
    let remaining = readDeadline?.timeIntervalSince(now()) ?? 30
    guard remaining > 0 else {
      throw MailBridgeError.mailAutomation("扫描超过 60 秒；本次未完成，不能推进游标。请减小 limit 后重新处理完整窗口。")
    }
    let deadlineScript = readDeadline.map { dateScript($0, name: "bridgeDeadline", rounding: .down) } ?? ""
    let boundedSource = "\(deadlineScript)\nwith timeout of \(min(30, Int(ceil(remaining)))) seconds\n\(source)\nend timeout"
    if let executor {
      let result = try executor(boundedSource)
      try checkReadDeadline()
      return result
    }
    guard let script = NSAppleScript(source: boundedSource) else {
      throw MailBridgeError.mailAutomation("无法编译 Apple“邮件”脚本。")
    }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
      let message = (error[NSAppleScript.errorMessage] as? String) ?? error.description
      if message.contains("scan_timeout") || (error[NSAppleScript.errorNumber] as? Int) == -1712 {
        throw MailBridgeError.mailAutomation("Apple“邮件”操作超时；结果未确认，不得自动重试写入或推进游标。")
      }
      if message.contains("Not authorized") || message.contains("不允许") || message.contains("-1743") {
        throw MailBridgeError.permissionDenied("MailBridge 没有控制 Apple“邮件”的权限：\(message)")
      }
      if message.contains("message_not_found") {
        throw MailBridgeError.notFound("指定邮件已不在收件箱中。")
      }
      if message.contains("attachment_not_found") {
        throw MailBridgeError.notFound("找不到指定附件。")
      }
      throw MailBridgeError.mailAutomation("Apple“邮件”脚本失败：\(message)")
    }
    try checkReadDeadline()
    return result
  }

  private func checkReadDeadline() throws {
    if let readDeadline, now() >= readDeadline {
      throw MailBridgeError.mailAutomation("扫描超过 60 秒；本次未完成，不能推进游标。请减小 limit 后重新处理完整窗口。")
    }
  }

  // Construct absolute dates without locale-dependent date strings or elapsed
  // scan time shifting the frozen window and fallback fingerprints.
  private func dateScript(_ date: Date, name: String, rounding: FloatingPointRoundingRule) -> String {
    let rounded = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(rounding))
    let calendar = Calendar(identifier: .gregorian)
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: rounded)
    let seconds = parts.hour! * 3600 + parts.minute! * 60 + parts.second!
    return """
      set \(name) to current date
      set day of \(name) to 1
      set year of \(name) to \(parts.year!)
      set month of \(name) to \(parts.month!)
      set day of \(name) to \(parts.day!)
      set time of \(name) to \(seconds)
      """
  }

  private func appleScriptLiteral(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    return "\"\(escaped)\""
  }
}

private extension NSAppleEventDescriptor {
  var listItems: [NSAppleEventDescriptor] {
    guard numberOfItems > 0 else { return [] }
    return (1...numberOfItems).compactMap { atIndex($0) }
  }

  func at(_ index: Int) -> NSAppleEventDescriptor {
    atIndex(index) ?? NSAppleEventDescriptor(string: "")
  }

  func string(at index: Int) -> String { at(index).stringValue ?? "" }
  func optionalString(at index: Int) -> String? {
    let value = string(at: index)
    return value.isEmpty ? nil : value
  }
  func bool(at index: Int) -> Bool { at(index).booleanValue }
  func int(at index: Int) -> Int { Int(at(index).int32Value) }
  func int64(at index: Int) -> Int64 {
    if let value = at(index).stringValue, let parsed = Int64(value) { return parsed }
    return Int64(at(index).int32Value)
  }
}
