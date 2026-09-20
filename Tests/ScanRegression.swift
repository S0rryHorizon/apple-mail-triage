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
    .init(boolean: false), .init(int32: -1), .init(int32: 0),
  ])
}

final class FakeMail {
  var accounts = [("active", true)]
  var rows: [NSAppleEventDescriptor] = []
  var previews: [Int] = []
  var failAccounts = false
  var failMetadata = false
  var failBody = false
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
    if source.contains("return content of targetMessage") {
      let id = number(#"whose id is (\d+)"#, source)
      previews.append(id)
      if failBody { throw MailBridgeError.mailAutomation("synthetic body timeout") }
      return .init(string: "Please submit by Friday. Your verification code: 123456")
    }
    if source.contains("set attachmentOutput") {
      let metadata = rows[0]
      var fields = (1...10).map { metadata.atIndex($0)! }
      fields.append(list([]))
      fields.append(.init(string: ""))
      expect(!source.contains("content of targetMessage"), "Zero-length read fetched a body")
      return list(fields)
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

try scenario("metadata-only") { _, mail, service in
  mail.rows = [row(1), row(2)]
  let response = try service.handle(scan(preview: 0))
  expect(response.messages?.count == 2 && mail.previews.isEmpty, "Zero preview fetched content")
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

print("Mail scan: \(checkCount) synthetic scenarios passed; no Apple Mail access")
