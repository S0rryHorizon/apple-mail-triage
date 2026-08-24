@preconcurrency import AppKit
import Foundation
import MailBridgeCore

final class MailAutomation {
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
    return descriptor.listItems.map { item in
      MailAccount(id: item.string(at: 1), name: item.string(at: 2), enabled: item.bool(at: 3))
    }
  }

  func scan(
    since: Date,
    until: Date,
    offset: Int,
    limit: Int,
    previewCharacters: Int
  ) throws -> [MailMessage] {
    let age = max(0, Int(Date().timeIntervalSince(since)))
    let upperAge = max(0, Int(Date().timeIntervalSince(until)))
    let safeOffset = max(offset, 0)
    let safeLimit = min(max(limit, 1), 1_001)
    let descriptor = try run(
      """
      tell application "Mail"
        set cutoffDate to (current date) - \(age)
        set upperDate to (current date) - \(upperAge)
        set nowDate to current date
        set output to {}
        set candidates to every message of inbox whose date received is greater than or equal to cutoffDate and date received is less than or equal to upperDate
        set skipped to 0
        set emitted to 0
        repeat with msg in candidates
          if skipped is less than \(safeOffset) then
            set skipped to skipped + 1
          else
          if emitted is greater than or equal to \(safeLimit) then exit repeat
          try
            set boxRef to mailbox of msg
            set acctRef to account of boxRef
            set rfcId to ""
            try
              set rfcId to message id of msg as text
            end try
            set bodyText to ""
            try
              set bodyText to content of msg as text
            end try
            set ageSeconds to nowDate - (date received of msg)
            set attachmentTotal to 0
            try
              set attachmentTotal to count of mail attachments of msg
            end try
            set end of output to {(id of acctRef as text), (name of acctRef as text), (name of boxRef as text), (id of msg as integer), rfcId, ageSeconds, (sender of msg as text), (subject of msg as text), (read status of msg as boolean), (flag index of msg as integer), attachmentTotal, bodyText}
            set emitted to emitted + 1
          end try
          end if
        end repeat
        return output
      end tell
      """)
    let now = Date()
    var result: [MailMessage] = []
    for item in descriptor.listItems {
      let accountId = item.string(at: 1)
      let libraryId = item.int64(at: 4)
      guard !accountId.isEmpty, libraryId > 0 else { continue }
      let messageId = item.optionalString(at: 5)
      let receivedAt = DateCodec.string(now.addingTimeInterval(-item.double(at: 6)))
      let sender = PrivacyFilter.sanitize(item.string(at: 7), limit: 500)
      let subject = PrivacyFilter.sanitize(item.string(at: 8), limit: 1_000)
      let text = PrivacyFilter.sanitize(item.string(at: 12), limit: previewCharacters)
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
        sanitizedText: text,
        isRead: item.bool(at: 9),
        flagIndex: item.int(at: 10),
        attachmentCount: item.int(at: 11),
        attachments: nil,
        fingerprint: fingerprint,
        hint: TriageRules.hint(sender: sender, subject: subject, text: text)
      ))
    }
    return result.sorted { $0.receivedAt > $1.receivedAt }
  }

  func read(ref: MessageRef, maxCharacters: Int) throws -> MailMessage {
    let descriptor = try run(findMessageScript(ref: ref, body: """
      set bodyText to ""
      try
        set bodyText to content of targetMessage as text
      end try
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
      set nowDate to current date
      set boxRef to mailbox of targetMessage
      set acctRef to account of boxRef
      set rfcId to ""
      try
        set rfcId to message id of targetMessage as text
      end try
      return {(id of acctRef as text), (name of acctRef as text), (name of boxRef as text), (id of targetMessage as integer), rfcId, (nowDate - (date received of targetMessage)), (sender of targetMessage as text), (subject of targetMessage as text), (read status of targetMessage as boolean), (flag index of targetMessage as integer), attachmentOutput, bodyText}
      """))
    let now = Date()
    let accountId = descriptor.string(at: 1)
    let libraryId = descriptor.int64(at: 4)
    guard !accountId.isEmpty, libraryId > 0 else {
      throw MailBridgeError.notFound("找不到指定邮件。")
    }
    let messageId = descriptor.optionalString(at: 5)
    let receivedAt = DateCodec.string(now.addingTimeInterval(-descriptor.double(at: 6)))
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
    guard let script = NSAppleScript(source: source) else {
      throw MailBridgeError.mailAutomation("无法编译 Apple“邮件”脚本。")
    }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
      let message = (error[NSAppleScript.errorMessage] as? String) ?? error.description
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
    return result
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
  func double(at index: Int) -> Double {
    if let value = at(index).stringValue, let parsed = Double(value) { return parsed }
    return Double(at(index).int32Value)
  }
}
