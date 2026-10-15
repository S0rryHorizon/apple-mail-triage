import AppKit
import Foundation
import MailBridgeCore
import SQLite3

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
  if !value() { fatalError(message) }
}

func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
  let result = NSAppleEventDescriptor.list()
  for (index, value) in values.enumerated() { result.insert(value, at: index + 1) }
  return result
}

func row(_ id: Int32, account: String = "active", date: String = "2026-08-19T08:00:00Z", messageId: String? = nil) -> NSAppleEventDescriptor {
  list([
    .init(string: account), .init(string: "Synthetic account"), .init(string: "INBOX"),
    .init(int32: id), .init(string: messageId ?? ""), .init(date: DateCodec.date(date)!),
    .init(string: "sender@example.test"), .init(string: "Synthetic message"),
    .init(boolean: false), .init(int32: 0),
  ])
}

final class FakeMail {
  var accounts = [("active", true)]
  var rows: [NSAppleEventDescriptor] = []
  var previews: [Int] = []
  var failAccounts = false
  var failMetadata = false
  var failBody = false
  var timeoutBodies: Set<Int> = []
  var bodies: [Int: String] = [:]
  var renderedBodies: [Int: String] = [:]
  var renderedReads: [Int] = []
  var failRenderedBody = false
  var attachmentName: String?
  var attachmentData = Data()
  var exportedPath: String?
  var clock = Date()
  var expireAfterMetadata = false
  var compiledScripts = 0

  lazy var automation = MailAutomation(executor: { [unowned self] source in
    var compilationError: NSDictionary?
    expect(NSAppleScript(source: source)!.compileAndReturnError(&compilationError), "Invalid AppleScript: \(String(describing: compilationError))")
    compiledScripts += 1
    if source.contains("repeat with acct in every account") {
      if failAccounts { throw MailBridgeError.permissionDenied("synthetic account failure") }
      return list(accounts.map { list([.init(string: $0.0), .init(string: "Synthetic account"), .init(boolean: $0.1)]) })
    }
    if source.contains("set cutoffDate") {
      if failMetadata { throw MailBridgeError.mailAutomation("synthetic metadata failure") }
      expect(!source.contains("content of"), "Metadata scan fetched a body")
      let offset = number(#"skipped is less than (\d+)"#, source)
      let limit = number(#"emitted is greater than or equal to (\d+)"#, source)
      if expireAfterMetadata { clock = clock.addingTimeInterval(61) }
      return list(Array(rows.dropFirst(offset).prefix(limit)))
    }
    if source.contains("return source of targetMessage") {
      let id = number(#"whose id is (\d+)"#, source)
      previews.append(id)
      if failBody { throw MailBridgeError.mailAutomation("synthetic body script error") }
      if timeoutBodies.contains(id) {
        throw MailBridgeError.diagnosedAutomation("synthetic", ["reason": "apple_event_timeout", "operation": "source"])
      }
      if let body = bodies[id] { return .init(string: body) }
      return .init(string: "Content-Type: text/plain; charset=utf-8\r\n\r\nPlease submit by Friday. Your verification code: 123456")
    }
    if source.contains("return content of targetMessage") {
      let id = number(#"whose id is (\d+)"#, source)
      renderedReads.append(id)
      if failRenderedBody { throw MailBridgeError.mailAutomation("synthetic fallback timeout") }
      return .init(string: renderedBodies[id] ?? "")
    }
    if source.contains("set attachmentOutput") {
      let metadata = rows[0]
      var fields = (1...9).map { metadata.atIndex($0)! }
      fields.append(list(attachmentName.map { [list([.init(string: "synthetic-attachment"), .init(string: $0), .init(string: ""), .init(int32: Int32(attachmentData.count)), .init(boolean: true)])] } ?? []))
      fields.append(.init(string: ""))
      expect(!source.contains("content of targetMessage"), "Zero-length read fetched a body")
      return list(fields)
    }
    if source.contains("save targetAttachment") {
      let expression = try! NSRegularExpression(pattern: #"save targetAttachment in POSIX file \"([^\"]+)\""#)
      let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))!
      let path = (source as NSString).substring(with: match.range(at: 1))
      try attachmentData.write(to: URL(fileURLWithPath: path))
      exportedPath = path
      return .init(string: path)
    }
    fatalError("Unexpected Mail operation")
  }, now: { [unowned self] in clock })

  func number(_ pattern: String, _ source: String) -> Int {
    let regex = try! NSRegularExpression(pattern: pattern)
    let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))!
    return Int((source as NSString).substring(with: match.range(at: 1)))!
  }
}

let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
var checkCount = 0

func scenario(_ name: String, _ body: (StateStore, FakeMail, MailBridgeService) throws -> Void) throws {
  let directory = temp.appendingPathComponent(name)
  setenv("MAIL_TRIAGE_STATE_DIR", directory.path, 1)
  let store = try StateStore()
  let mail = FakeMail()
  let service = MailBridgeService(automation: mail.automation, store: store)
  try body(store, mail, service)
  checkCount += 1
}

func scan(limit: Int = 200, preview: Int = 800, offset: Int = 0) -> BridgeRequest {
  var request = BridgeRequest(action: "message.scan")
  request.since = "2026-08-01T00:00:00Z"
  request.until = "2026-08-31T23:59:59Z"
  request.limit = limit
  request.previewCharacters = preview
  request.offset = offset
  return request
}

func record(_ store: StateStore, _ object: [String: Any]) throws {
  // Seed only this test's temporary database, including historical orphan rows
  // that the current account-validation policy may correctly reject on write.
  let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAIL_TRIAGE_STATE_DIR"]!)
  expect(directory.path.hasPrefix(temp.path + "/"), "Refusing to seed non-test state")
  var db: OpaquePointer?
  expect(sqlite3_open(directory.appendingPathComponent("state.sqlite").path, &db) == SQLITE_OK, "Open fixture state")
  defer { sqlite3_close(db) }
  func insert(_ sql: String, _ values: [String]) {
    var statement: OpaquePointer?
    expect(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, "Prepare fixture state")
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
    expect(sqlite3_step(statement) == SQLITE_DONE, "Insert fixture state")
  }
  for cursor in object["cursors"] as? [[String: String]] ?? [] {
    insert("INSERT INTO cursors(account_id, received_at, updated_at) VALUES(?, ?, ?)",
           [cursor["accountId"]!, cursor["receivedAt"]!, cursor["receivedAt"]!])
  }
  for message in object["processed"] as? [[String: Any]] ?? [] {
    let ref = message["ref"] as! [String: Any]
    insert("INSERT INTO processed_messages(account_id, library_id, fingerprint, received_at, category, processed_at) VALUES(?, ?, ?, ?, ?, ?)",
           [ref["accountId"] as! String, String(ref["libraryId"] as! Int), message["fingerprint"] as! String,
            message["receivedAt"] as! String, message["category"] as! String, message["receivedAt"] as! String])
  }
}

func mustFail(_ action: () throws -> Void) {
  do { try action(); fatalError("Operation incorrectly succeeded") } catch {}
}

let mime = """
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="outer"

--outer
Content-Type: multipart/alternative; boundary="inner"

--inner
Content-Type: text/plain; charset=utf-8
Content-Transfer-Encoding: base64

\(Data("实验 reminder\nPlease submit by Friday.".utf8).base64EncodedString())
--inner
Content-Type: text/html; charset=utf-8

<p>Alternative version</p>
--inner--
--outer
Content-Type: text/plain
Content-Disposition: attachment; filename="private.txt"

Attachment must not become body
--outer--
"""
let decoded = try SourceBody.decode(mime)
expect(decoded == "实验 reminder\nPlease submit by Friday.", "MIME alternative/attachment/charset decoding failed")
let html = try SourceBody.decode("Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\n<head><style>hidden CSS</style></head><p>Hello &amp; welcome</p><script>hidden code</script><p>Deadline =3D Friday<img src='https://example.test/pixel'></p>")
expect(html.contains("Hello & welcome") && html.contains("Deadline = Friday"), "HTML text/transfer decoding failed")
expect(!html.contains("hidden") && !html.contains("pixel"), "HTML code or resource leaked")
mustFail { _ = try SourceBody.decode("Content-Type: multipart/mixed; boundary=missing\n\nBroken MIME") }
mustFail { _ = try SourceBody.decode("Content-Type: application/octet-stream\n\nNo text body") }
let largeAttachmentMIME = "Content-Type: multipart/mixed; boundary=large\n\n--large\nContent-Type: text/plain\n\nSmall body\n--large\nContent-Type: application/octet-stream\nContent-Disposition: attachment; filename=synthetic.bin\nContent-Transfer-Encoding: base64\n\n" + String(repeating: "QUFB\n", count: 2_200_000) + "\n--large--\n"
let largeAttachmentBody = try SourceBody.decode(largeAttachmentMIME)
expect(largeAttachmentBody == "Small body", "Large attachment prevented small body decoding")
mustFail { _ = try SourceBody.decode(String(repeating: "x", count: 40 * 1024 * 1024 + 1)) }
mustFail { _ = try SourceBody.decode("Content-Type: text/plain\n\n" + String(repeating: "x", count: 10 * 1024 * 1024 + 1)) }

try scenario("dedupe-before-body") { store, mail, service in
  mail.rows = [row(1, messageId: "known@example.test"), row(2, messageId: "known@example.test"), row(3), row(4)]
  try record(store, ["processed": [["ref": ["accountId": "active", "libraryId": 1], "fingerprint": PrivacyFilter.fingerprint(accountId: "active", libraryId: 1, messageId: "known@example.test", receivedAt: "", subject: ""), "receivedAt": "2026-08-19T08:00:00Z", "category": "information"]]])
  let before = try store.summary()
  let response = try service.handle(scan(limit: 3))
  expect(mail.previews == [3], "Processed/duplicate/lookahead body fetched")
  expect(response.messages?.count == 1, "Unexpected new message count")
  expect(response.details?["hasMore"] == "true", "Lookahead lost")
  expect(response.messages?.first?.sanitizedText?.contains("123456") == false, "Unsanitized preview")
  expect(response.messages?.first?.hint == .action, "Body did not inform classification")
  let after = try store.summary()
  expect(before == after, "Scan changed state")
}

try scenario("full-read-source-body") { _, mail, service in
  mail.rows = [row(1)]
  var request = BridgeRequest(action: "message.read")
  request.ref = MessageRef(accountId: "active", libraryId: 1)
  request.maxBodyCharacters = 8_000
  let response = try service.handle(request)
  expect(response.messages?.first?.sanitizedText?.contains("Please submit") == true, "Full read lost decoded body")
  expect(response.messages?.first?.sanitizedText?.contains("123456") == false, "Full read skipped privacy filter")
}

try scenario("metadata-only") { _, mail, service in
  mail.rows = [row(1), row(2)]
  let response = try service.handle(scan(preview: 0))
  expect(response.messages?.count == 2 && mail.previews.isEmpty, "Zero preview fetched content")
  expect(response.state != nil && response.rules != nil, "Scan must include state and rules")
}

try scenario("unordered-lookahead") { _, mail, service in
  mail.rows = [row(1, date: "2026-08-17T08:00:00Z"), row(2, date: "2026-08-18T08:00:00Z"), row(3, date: "2026-08-19T08:00:00Z")]
  let first = try service.handle(scan(limit: 2, preview: 0))
  let second = try service.handle(scan(limit: 2, preview: 0, offset: 2))
  expect(first.messages?.map(\.ref.libraryId) == [2, 1], "Sorted lookahead displaced a page member")
  expect(second.messages?.map(\.ref.libraryId) == [3], "Pagination skipped or duplicated a row")
  expect(first.details?["nextOffset"] == "2" && second.details?["hasMore"] == "false", "Incorrect raw offsets")
}

try scenario("orphan-and-disabled-cursors") { store, mail, service in
  mail.accounts = [("active", true), ("disabled", false)]
  try record(store, ["cursors": [["accountId": "active", "receivedAt": "2026-08-20T08:00:00Z"], ["accountId": "orphan", "receivedAt": "2000-01-01T00:00:00Z"], ["accountId": "disabled", "receivedAt": "2001-01-01T00:00:00Z"]]])
  let before = try store.summary()
  let response = try service.handle(BridgeRequest(action: "message.scan"))
  expect(response.details?["since"] == "2026-08-20T07:45:00.000Z", "Inactive cursor widened the window")
  let after = try store.summary()
  expect(before == after && after.cursors.count == 3, "Cursor was deleted or advanced")
}

try scenario("new-account-lookback") { store, mail, service in
  mail.accounts = [("active", true), ("new", true)]
  let now = Date()
  try record(store, ["cursors": [["accountId": "active", "receivedAt": DateCodec.string(now)]]])
  let response = try service.handle(BridgeRequest(action: "message.scan"))
  let since = DateCodec.date(response.details!["since"]!)!
  expect(abs(since.timeIntervalSince(now.addingTimeInterval(-86400))) < 5, "Missing cursor lost initial 24 hours")
}

try scenario("disabled-messages") { _, mail, service in
  mail.accounts.append(("disabled", false))
  mail.rows = [row(1, account: "disabled"), row(2)]
  let response = try service.handle(scan())
  expect(response.messages?.map(\.ref.libraryId) == [2] && mail.previews == [2], "Disabled account read")
}

try scenario("stable-dates-and-fingerprints") { _, mail, service in
  mail.rows = [row(1)]
  let first = try service.handle(scan(preview: 0)).messages![0]
  mail.clock = mail.clock.addingTimeInterval(120)
  let second = try service.handle(scan(preview: 0)).messages![0]
  let read = try mail.automation.read(ref: first.ref, maxCharacters: 0)
  expect(first.receivedAt == "2026-08-19T08:00:00.000Z", "Receive date drifted")
  expect(first.fingerprint == second.fingerprint && first.fingerprint == read.fingerprint, "Fallback fingerprint drifted")
}

for failure in ["accounts", "metadata", "body", "malformed", "deadline"] {
  try scenario("failure-\(failure)") { store, mail, service in
    mail.rows = [row(1)]
    mail.failAccounts = failure == "accounts"
    mail.failMetadata = failure == "metadata"
    mail.failBody = failure == "body"
    mail.expireAfterMetadata = failure == "deadline"
    if failure == "malformed" { mail.rows = [list([.init(string: "invalid")])] }
    let before = try store.summary()
    mustFail { _ = try service.handle(scan()) }
    let after = try store.summary()
    expect(before == after, "Failed scan changed state")
    if failure == "deadline" { expect(mail.previews.isEmpty, "Read continued past deadline") }
  }
}

try scenario("isolated-body-failure-and-cursor-safety") { store, mail, service in
  mail.rows = [row(1), row(2, date: "2026-08-20T08:00:00Z")]
  mail.bodies[1] = "Content-Type: multipart/mixed; boundary=missing\n\nBroken MIME"
  let response = try service.handle(scan())
  expect(response.ok && response.status == "partial" && response.messages?.count == 2, "One malformed body stopped the page")
  expect(response.messages?.first?.sanitizedText?.contains("Please submit") == true, "Healthy body lost")
  expect(response.messages?.last?.bodyReadError == "body_decode_failed", "Unread body was concealed")
  let zeroPreview = try service.handle(scan(preview: 0))
  expect(zeroPreview.messages?.last?.bodyReadError != nil, "Metadata-only scan cleared unread failure")
  func save(_ ids: [Int]) throws {
    let processed = response.messages!.filter { ids.contains(Int($0.ref.libraryId)) }.map {
      ["ref": ["accountId": $0.ref.accountId, "libraryId": $0.ref.libraryId], "fingerprint": $0.fingerprint,
       "receivedAt": $0.receivedAt, "category": "information"] as [String: Any]
    }
    let data = try JSONSerialization.data(withJSONObject: ["action": "state.record", "state": ["processed": processed,
      "cursors": [["accountId": "active", "receivedAt": "2026-08-20T08:00:00Z"]]]])
    _ = try service.handle(JSONDecoder().decode(BridgeRequest.self, from: data))
  }
  mustFail { try save([1, 2]) }
  expect(try! store.summary().processedCount == 0, "Rejected save partially committed")
  try save([2])
  let saved = try store.summary()
  expect(saved.processedCount == 1 && saved.deferredBodyCount == 1, "Healthy mail was not saved separately")
  expect(DateCodec.date(saved.cursors[0].receivedAt)! < DateCodec.date("2026-08-19T08:00:00Z")!, "Cursor skipped unread mail")
  mail.bodies.removeValue(forKey: 1)
  let next = try service.handle(scan())
  expect(next.messages?.count == 1 && next.messages?[0].ref.libraryId == 1, "Unread mail was lost or healthy mail repeated")
  try save([1])
  expect(try! store.summary().deferredBodyCount == 0, "Successful reread did not clear pending failure")
}

try scenario("header-only-source-uses-rendered-body") { store, mail, service in
  mail.rows = [row(1), row(2)]
  mail.bodies[1] = "Content-Type: multipart/mixed; boundary=missing\r\n\r\n"
  mail.renderedBodies[1] = "Confirmed appointment. Verification code: 123456"
  let response = try service.handle(scan())
  let recovered = response.messages!.first { $0.ref.libraryId == 1 }!
  expect(recovered.bodyReadError == nil && recovered.sanitizedText!.contains("Confirmed appointment"), "Available rendered body was lost")
  expect(!recovered.sanitizedText!.contains("123456"), "Fallback bypassed privacy filter")
  expect(mail.renderedReads == [1], "Healthy MIME used rendered fallback")
  expect(try! store.summary().deferredBodyCount == 0, "Recovered body remained deferred")
  mail.renderedBodies[1] = " \n"
  let unread = try service.handle(scan()).messages!.first { $0.ref.libraryId == 1 }!
  expect(unread.bodyReadError == "source_body_missing", "Empty fallback was accepted as a complete body")
  expect(try! store.summary().deferredBodyCount == 1, "Unavailable fallback was not retained")
}

try scenario("rendered-body-timeout-remains-operational") { store, mail, service in
  mail.rows = [row(1)]
  mail.bodies[1] = "Content-Type: multipart/mixed; boundary=missing\n\n"
  mail.failRenderedBody = true
  let before = try store.summary()
  mustFail { _ = try service.handle(scan()) }
  expect(try! store.summary() == before, "Timed-out fallback advanced state")
}

try scenario("invalid-charset-does-not-use-rendered-fallback") { _, mail, service in
  mail.rows = [row(1)]
  mail.bodies[1] = "Content-Type: text/plain; charset=unknown-synthetic-charset\n\ntext"
  mail.renderedBodies[1] = "Must not bypass malformed MIME"
  let response = try service.handle(scan())
  expect(response.messages?.first?.bodyReadError == "body_decode_failed", "Malformed body was silently accepted")
  expect(mail.renderedReads.isEmpty, "Unrelated decoder error triggered fallback")
}

try scenario("attachment-text-cleans-success-and-failure") { store, mail, service in
  mail.rows = [row(1)]
  mail.attachmentName = "synthetic.txt"
  mail.attachmentData = Data("Synthetic attachment. Verification code: 123456\n".utf8)
  var request = BridgeRequest(action: "attachment.text")
  request.ref = MessageRef(accountId: "active", libraryId: 1)
  request.attachmentId = "synthetic-attachment"
  request.maxBodyCharacters = 200
  let result = try service.handle(request)
  expect(result.text?.contains("Synthetic attachment") == true && result.text?.contains("123456") == false, "Text extraction or privacy filter failed")
  expect(result.details?["cleanup"] == "cleaned", "Cleanup was not confirmed")
  expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: mail.exportedPath!).deletingLastPathComponent().path), "Successful conversion left attachment")
  let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAIL_TRIAGE_TEST_FIXTURES"]!)
  for ext in ["pdf", "docx", "xlsx"] {
    mail.attachmentName = "synthetic.\(ext)"
    mail.attachmentData = try Data(contentsOf: fixtures.appendingPathComponent(mail.attachmentName!))
    let converted = try service.handle(request)
    expect(converted.text?.contains("Synthetic") == true, "\(ext) text extraction failed")
    expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: mail.exportedPath!).deletingLastPathComponent().path), "\(ext) conversion left attachment")
  }
  mail.attachmentName = "long.txt"
  mail.attachmentData = Data(String(repeating: "Synthetic text. ", count: 50).utf8)
  request.maxBodyCharacters = 50
  let short = try service.handle(request)
  expect(short.details?["truncated"] == "true", "Truncation concealed")
  mail.attachmentName = "broken.pdf"
  mail.attachmentData = Data("Not a PDF".utf8)
  mustFail { _ = try service.handle(request) }
  expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: mail.exportedPath!).deletingLastPathComponent().path), "Failed conversion left attachment")
  expect(try! store.expiredExports(before: Date.distantFuture).isEmpty, "Conversion left cleanup tokens")
}

try scenario("stale-attachment-cleanup-boundary") { store, _, _ in
  let root = temp.appendingPathComponent("owned-exports")
  let old = root.appendingPathComponent(UUID().uuidString)
  let fresh = root.appendingPathComponent(UUID().uuidString)
  let unrelated = root.appendingPathComponent("keep-user-folder")
  let outside = temp.appendingPathComponent("outside")
  for dir in [old, fresh, unrelated, outside] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
  let token = try store.registerExport(path: old.path)
  var db: OpaquePointer?
  let dbPath = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAIL_TRIAGE_STATE_DIR"]!).appendingPathComponent("state.sqlite").path
  expect(sqlite3_open(dbPath, &db) == SQLITE_OK, "Open temporary fixture DB")
  expect(sqlite3_exec(db, "UPDATE temp_exports SET created_at='2000-01-01T00:00:00Z';", nil, nil, nil) == SQLITE_OK, "Age fixture token")
  sqlite3_close(db)
  let link = root.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
  mustFail { try TemporaryAttachments.remove(outside.path, root: root) }
  mustFail { try TemporaryAttachments.remove(link.path, root: root) }
  try TemporaryAttachments.sweep(store: store, root: root)
  expect(!FileManager.default.fileExists(atPath: old.path), "Stale export remained")
  mustFail { _ = try store.exportPath(token: token) }
  for dir in [fresh, unrelated, outside] { expect(FileManager.default.fileExists(atPath: dir.path), "Cleanup removed fresh/unrelated data") }
  let orphan = root.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: orphan.path)
  try TemporaryAttachments.sweep(store: store, root: root)
  expect(!FileManager.default.fileExists(atPath: orphan.path), "Abandoned unregistered directory remained")
}

try scenario("oversize-body-isolated") { store, mail, service in
  mail.rows = [row(1), row(2)]
  mail.bodies[1] = String(repeating: "x", count: 40 * 1024 * 1024 + 1)
  let result = try service.handle(scan())
  expect(result.messages?.count == 2 && result.status == "partial", "Oversize mail blocked healthy mail")
  expect(result.messages?[0].bodyReadError == "source_size_limit", "Oversize mail lost its diagnostic")
  expect(result.messages?[1].sanitizedText?.contains("Please submit") == true, "Mail after oversize body was not read")
  expect(try! store.summary().processedCount == 0, "Scan incorrectly marked mail processed")
}

try scenario("deadline-diagnostics-preserve-operation") { store, mail, service in
  mail.rows = [row(1)]
  mail.expireAfterMetadata = true
  do {
    _ = try service.handle(scan())
    fatalError("Expected deadline failure")
  } catch let error as MailBridgeError {
    expect(error.code == "mail_automation_failure", "Changed operational failure code")
    expect(error.diagnostics?["reason"] == "scan_deadline", "Lost deadline reason")
    expect(error.diagnostics?["operation"] == "metadata", "Lost failing stage")
  }
}
try scenario("body-timeout-defers-mail-without-failing-scan") { store, mail, service in
  mail.rows = [row(1, date: "2026-08-19T08:00:00Z"), row(2, date: "2026-08-20T08:00:00Z"), row(3, date: "2026-08-21T08:00:00Z")]
  mail.timeoutBodies = [1]
  let response = try service.handle(scan())
  expect(response.ok && response.status == "partial" && response.messages?.count == 3, "A slow body failed the whole scan")
  expect(response.messages!.allSatisfy { $0.bodyReadError == "body_timeout" }, "Bodies after a timeout were not deferred")
  expect(mail.previews == [1], "Scan kept waiting on a stalled Mail after one body timeout")
  expect(try! store.summary().deferredBodyCount == 3, "Timed-out bodies were not retained as unread")
  mail.timeoutBodies = []
  let read = try service.handle({ var request = BridgeRequest(action: "message.read"); request.ref = response.messages![0].ref; return request }())
  expect(read.messages?.first?.bodyReadError == nil, "Recovered body stayed deferred")
  mail.timeoutBodies = [2]
  var timedOutRead = BridgeRequest(action: "message.read")
  timedOutRead.ref = response.messages!.first { $0.ref.libraryId == 2 }!.ref
  let timedOut = try service.handle(timedOutRead)
  expect(timedOut.messages?.first?.bodyReadError == "body_timeout", "Timed-out read was not a content limitation")
  mail.timeoutBodies = []
  let reread = try service.handle(scan())
  expect(reread.messages?.allSatisfy { $0.bodyReadError == nil } == true, "Deferred mail was not reread")
  expect(try! store.summary().deferredBodyCount == 0, "Reread did not clear deferred bodies")
}

try scenario("window-until-advances-quiet-accounts") { store, mail, service in
  mail.accounts = [("active", true), ("quiet", true), ("blocked", true), ("disabled", false)]
  try record(store, ["cursors": [
    ["accountId": "active", "receivedAt": "2026-08-10T00:00:00Z"],
    ["accountId": "quiet", "receivedAt": "2026-08-01T00:00:00Z"],
    ["accountId": "blocked", "receivedAt": "2026-08-01T00:00:00Z"],
    ["accountId": "disabled", "receivedAt": "2026-08-01T00:00:00Z"]]])
  mail.rows = [row(5, account: "blocked", date: "2026-08-05T00:00:00Z")]
  mail.bodies[5] = "Content-Type: multipart/mixed; boundary=missing\n\nBroken MIME"
  _ = try service.handle(scan())
  func save(_ state: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: ["action": "state.record", "state": state])
    _ = try service.handle(JSONDecoder().decode(BridgeRequest.self, from: data))
  }
  mustFail { try save(["windowUntil": DateCodec.string(Date().addingTimeInterval(3600))]) }
  try save(["windowUntil": "2026-08-31T23:59:59Z"])
  let cursors = Dictionary(uniqueKeysWithValues: try store.summary().cursors.map { ($0.accountId, $0.receivedAt) })
  expect(cursors["active"] == "2026-08-31T23:59:59.000Z" && cursors["quiet"] == "2026-08-31T23:59:59.000Z", "Quiet account still anchors the window")
  expect(DateCodec.date(cursors["blocked"]!)! < DateCodec.date("2026-08-05T00:00:00Z")!, "Window advance skipped unread mail")
  expect(cursors["disabled"] == "2026-08-01T00:00:00Z", "Disabled account cursor moved")
  expect(cursors.count == 4, "Window advance created cursors for unseen accounts")
}

print("Mail scan/cache: \(checkCount) synthetic scenarios passed; no Apple Mail access")
