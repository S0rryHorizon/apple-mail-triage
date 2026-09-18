import Foundation

public enum TriageRules {
  private static let riskTerms = [
    "new sign-in", "new login", "unrecognized", "suspicious", "security alert",
    "password changed", "异常登录", "安全提醒", "可疑活动", "未经授权", "付款失败",
    "payment failed", "chargeback", "account locked",
  ]
  private static let actionTerms = [
    "action required", "please submit", "please reply", "deadline", "due by",
    "需要你", "请提交", "请回复", "截止", "待完成", "required to",
  ]
  private static let noiseTerms = [
    "unsubscribe", "promotion", "special offer", "newsletter", "验证码", "verification code",
    "temporary code", "优惠", "促销", "广告邮件",
  ]
  private static let scheduleTerms = [
    "calendar invitation", "meeting invitation", "you are registered", "registration confirmed",
    "invitation accepted", "已报名", "报名成功", "会议邀请", "日历邀请",
  ]

  public static func hint(sender: String, subject: String, text: String) -> TriageCategory {
    let value = "\(sender) \(subject) \(text)".lowercased()
    if riskTerms.contains(where: value.contains) { return .risk }
    if actionTerms.contains(where: value.contains) { return .action }
    if scheduleTerms.contains(where: value.contains) { return .schedule }
    if noiseTerms.contains(where: value.contains) { return .noise }
    return .information
  }

  public static func candidateId(kind: CandidateKind, fingerprint: String, receivedAt: String) -> String {
    let date = receivedAt.prefix(10).replacingOccurrences(of: "-", with: "")
    let prefix = kind == .event ? "E" : "T"
    return "\(prefix)-\(date)-\(fingerprint.prefix(8).uppercased())"
  }

  public static func flagIndex(for color: String) throws -> Int {
    switch color.lowercased() {
    case "red": return 0
    case "orange": return 1
    default: throw MailBridgeError.invalidRequest("旗标颜色仅支持 red 或 orange。")
    }
  }

  public static let maximumAttachmentSize: Int64 = 10 * 1024 * 1024
  public static let maximumTotalAttachmentSize: Int64 = 20 * 1024 * 1024
  private static let attachmentMIMEs = [
    "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "pdf": "application/pdf", "csv": "text/csv", "tsv": "text/tab-separated-values",
    "txt": "text/plain", "md": "text/markdown",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ]

  public static func attachmentDecision(name: String, mimeType: String, size: Int64) -> AttachmentDecision {
    let ext = (name as NSString).pathExtension.lowercased()
    let raw = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
    let mime = raw.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let denied = ["zip", "rar", "7z", "dmg", "pkg", "app", "exe", "js", "command", "sh", "docm", "xlsm"]
    if denied.contains(ext) { return .rejected(.deniedExtension) }
    guard let expected = attachmentMIMEs[ext] else {
      return .rejected(raw.isEmpty ? .emptyMimeAndUnknownExtension : .unknownExtension)
    }
    guard size >= 0 else { return .rejected(.invalidSize) }
    guard size <= maximumAttachmentSize else { return .rejected(.fileTooLarge) }
    if raw.isEmpty { return .allowed(mimeType: expected, inferred: true) }
    guard mime == expected else { return .rejected(.mimeExtensionMismatch) }
    return .allowed(mimeType: expected, inferred: false)
  }

  public static func attachmentTotalRejection(sizes: [Int64]) -> AttachmentRejectionReason? {
    var total: Int64 = 0
    for size in sizes {
      guard size >= 0 else { return .invalidSize }
      guard size <= maximumTotalAttachmentSize - total else { return .totalSizeTooLarge }
      total += size
    }
    return nil
  }

  public static func attachmentAllowed(name: String, mimeType: String, size: Int64) -> Bool {
    if case .allowed = attachmentDecision(name: name, mimeType: mimeType, size: size) { return true }
    return false
  }
}

public enum AttachmentDecision: Equatable, Sendable {
  case allowed(mimeType: String, inferred: Bool)
  case rejected(AttachmentRejectionReason)
}

public enum AttachmentRejectionReason: String, Sendable {
  case emptyMimeAndUnknownExtension, mimeExtensionMismatch, deniedExtension, unknownExtension
  case invalidSize, fileTooLarge, totalSizeTooLarge

  public var message: String {
    switch self {
    case .emptyMimeAndUnknownExtension: return "MIME 为空且扩展名无法安全推断。"
    case .mimeExtensionMismatch: return "MIME 与扩展名冲突。"
    case .deniedExtension: return "危险扩展名。"
    case .unknownExtension: return "扩展名不在安全白名单内。"
    case .invalidSize: return "附件大小无效。"
    case .fileTooLarge: return "单文件超过 10 MB。"
    case .totalSizeTooLarge: return "邮件附件合计超过 20 MB。"
    }
  }
}
