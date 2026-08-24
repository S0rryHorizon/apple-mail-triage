import CryptoKit
import Foundation

public enum PrivacyFilter {
  private static let patterns: [(String, String)] = [
    (#"(?i)(?:(?:一次性|临时|动态)\s*)?(?:(?:verification|security|one[- ]?time|otp)\s*)?(?:code|验证码)(?:\s*以继续)?\s*[:：-]?\s*\d{4,8}"#, "[已移除验证码]"),
    (#"(?i)(一次性|临时|动态|verification|security|one[- ]?time|otp)(?:\s+(?:code|验证码))?\s*[:：-]?\s*\d{4,8}"#, "$1：[已移除验证码]"),
    (#"(?i)\b(?:code|验证码)\s*[:：-]?\s*\d{4,8}\b"#, "验证码：[已移除]"),
    (#"(?i)(bearer\s+)[A-Za-z0-9._~+\-/=]{12,}"#, "$1[已移除令牌]"),
    (#"(?i)((?:token|auth|session|signature|sig|key|code)=)[^&\s]+"#, "$1[已移除]"),
    (#"(?i)(?:https?://[^\s<>]+/(?:reset|verify|login|auth)[^\s<>]*)"#, "[已移除敏感链接]"),
    (#"(?i)(Visa|Mastercard|Amex|卡号|银行卡)[-\s]*(?:\*{0,4}|x{0,4})[-\s]*\d{4}\b"#, "$1-[已移除卡尾号]"),
    (#"(?i)((?:tel(?:ephone)?|phone|mobile|whatsapp|电话|联系电话)(?:\s+(?:msg|message))?(?:\s+at)?\s*[:：]?\s*)\+?\d[\d\s-]{6,}\d"#, "$1[已移除电话号码]"),
    (#"(?i)((?:order|subscription|订单|订阅)(?:\s*(?:number|id|编号))?\s*[:：]\s*)[A-Za-z0-9_-]{8,}"#, "$1[已移除编号]"),
  ]

  private static let sensitiveQuery = try! NSRegularExpression(
    pattern: #"(?i)([?&](?:token|auth|session|signature|sig|key|code)=)[^&\s]+"#)

  public static func sanitize(_ input: String, limit: Int? = nil) -> String {
    var output = input.replacingOccurrences(of: "\u{0000}", with: "")
    for (pattern, replacement) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(output.startIndex..<output.endIndex, in: output)
      output = regex.stringByReplacingMatches(
        in: output, range: range, withTemplate: replacement)
    }
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    output = sensitiveQuery.stringByReplacingMatches(
      in: output, range: range, withTemplate: "$1[已移除]"
    )
    output = output.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    output = output.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let limit, limit >= 0, output.count > limit else { return output }
    return String(output.prefix(limit)) + "…"
  }

  public static func fingerprint(
    accountId: String,
    libraryId: Int64,
    messageId: String?,
    receivedAt: String,
    subject: String
  ) -> String {
    let canonical: String
    if let messageId = messageId?.trimmingCharacters(in: .whitespacesAndNewlines), !messageId.isEmpty {
      canonical = "message-id|\(messageId.lowercased())"
    } else {
      canonical = "fallback|\(accountId)|\(libraryId)|\(receivedAt)|\(subject)"
    }
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
