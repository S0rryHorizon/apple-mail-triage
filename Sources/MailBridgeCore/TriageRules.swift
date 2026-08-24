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

  public static func attachmentAllowed(name: String, mimeType: String, size: Int64) -> Bool {
    guard size >= 0 && size <= 10 * 1024 * 1024 else { return false }
    let lowerName = name.lowercased()
    let denied = [".zip", ".rar", ".7z", ".dmg", ".pkg", ".app", ".exe", ".js", ".command", ".sh", ".docm", ".xlsm"]
    if denied.contains(where: lowerName.hasSuffix) { return false }
    let extensions = [".pdf", ".png", ".jpg", ".jpeg", ".heic", ".webp", ".txt", ".md", ".html", ".htm", ".docx", ".xlsx", ".csv", ".tsv"]
    let mimes = ["application/pdf", "text/", "image/", "application/vnd.openxmlformats-officedocument"]
    return extensions.contains(where: lowerName.hasSuffix)
      && mimes.contains(where: mimeType.lowercased().hasPrefix)
  }
}
