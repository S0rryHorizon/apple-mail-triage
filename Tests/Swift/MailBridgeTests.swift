import Foundation
import SQLite3
import MailBridgeCore
import MailBridgeRuntime

final class MailBridgeTests {
  func testAttachmentPolicy() {
    let mapping = ["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "pdf":"application/pdf", "csv":"text/csv", "tsv":"text/tab-separated-values", "txt":"text/plain", "md":"text/markdown", "docx":"application/vnd.openxmlformats-officedocument.wordprocessingml.document", "xlsx":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"]
    for (ext, mime) in mapping {
      XCTAssertEqual(TriageRules.attachmentDecision(name: "file.\(ext.uppercased())", mimeType: "", size: 1), .allowed(mimeType: mime, inferred: true))
      XCTAssertEqual(TriageRules.attachmentDecision(name: "file.\(ext)", mimeType: " \(mime.uppercased()); charset=UTF-8 ", size: 1), .allowed(mimeType: mime, inferred: false))
    }
    for ext in ["zip", "rar", "7z", "dmg", "pkg", "app", "exe", "js", "command", "sh", "docm", "xlsm"] {
      for mime in ["", "image/png", "application/zip"] {
        XCTAssertEqual(TriageRules.attachmentDecision(name: "file.\(ext)", mimeType: mime, size: 1), .rejected(.deniedExtension))
      }
    }
    XCTAssertEqual(TriageRules.attachmentDecision(name: "file.unknown", mimeType: "", size: 1), .rejected(.emptyMimeAndUnknownExtension))
    for mime in ["application/pdf", "; charset=UTF-8", "image/png-malicious", "application/octet-stream"] {
      XCTAssertEqual(TriageRules.attachmentDecision(name: "file.png", mimeType: mime, size: 1), .rejected(.mimeExtensionMismatch))
    }
    XCTAssertEqual(TriageRules.attachmentDecision(name: "file.png", mimeType: "", size: 10*1024*1024+1), .rejected(.fileTooLarge))
    XCTAssertTrue(TriageRules.attachmentAllowed(name: "file.png", mimeType: "", size: 10*1024*1024))
    XCTAssertEqual(TriageRules.attachmentTotalRejection(sizes: [10*1024*1024,10*1024*1024,1]), .totalSizeTooLarge)
    XCTAssertNil(TriageRules.attachmentTotalRejection(sizes: [10*1024*1024,10*1024*1024]))
    XCTAssertEqual(TriageRules.attachmentTotalRejection(sizes: [Int64.max, 1]), .totalSizeTooLarge)
    XCTAssertEqual(TriageRules.attachmentTotalRejection(sizes: [-1]), .invalidSize)
  }

  func testStateAtomicityAndRepair() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    let service = MailBridgeService(store: store, accountProvider: {
      [MailAccount(id: "a", name: "A", enabled: true), MailAccount(id: "disabled", name: "Disabled", enabled: false)]
    })
    func call(_ json: String) throws -> BridgeResponse {
      try service.handle(JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8)))
    }
    _ = try call(#"{"action":"state.record","state":{"cursors":[{"accountId":"a","receivedAt":"2026-09-11T10:00:00Z"}]}}"#)
    let before = try store.summary()
    let unavailable = MailBridgeService(store: store, accountProvider: {
      throw MailBridgeError.mailAutomation("Account lookup failed")
    })
    let blocked = try JSONDecoder().decode(BridgeRequest.self, from: Data(#"{"action":"state.record","state":{"shadowRunsCompleted":99}}"#.utf8))
    XCTAssertThrowsError(try unavailable.handle(blocked))
    XCTAssertEqual(try store.summary(), before)
    for field in [
      #""processed":[{"ref":{"accountId":"ghost","libraryId":1},"fingerprint":"f","receivedAt":"2026-09-11T10:00:00Z","category":"information"}]"#,
      #""candidates":[{"id":"T-1","kind":"reminder","title":"test","accountId":"ghost","libraryId":1,"sourceSubject":"test"}]"#,
      #""cursors":[{"accountId":"ghost","receivedAt":"2026-09-12T10:00:00Z"}]"#,
      #""cursors":[{"accountId":"disabled","receivedAt":"2026-09-12T10:00:00Z"}]"#
    ] {
      XCTAssertThrowsError(try call("{\"action\":\"state.record\",\"state\":{\"shadowRunsCompleted\":9,\(field)}}"))
      XCTAssertEqual(try store.summary(), before)
      XCTAssertEqual(try store.pendingCandidates(), [])
    }
    // A mixed request must not commit even its valid records before rejecting an unknown cursor.
    XCTAssertThrowsError(try call(#"{"action":"state.record","state":{"processed":[{"ref":{"accountId":"a","libraryId":1},"fingerprint":"f","receivedAt":"2026-09-11T10:00:00Z","category":"information"}],"candidates":[{"id":"T-1","kind":"reminder","title":"test","accountId":"a","libraryId":1,"sourceSubject":"test"}],"cursors":[{"accountId":"a","receivedAt":"2026-09-12T10:00:00Z"},{"accountId":"ghost","receivedAt":"2026-09-12T10:00:00Z"}]}}"#))
    XCTAssertEqual(try store.summary(), before)
    XCTAssertEqual(try store.pendingCandidates(), [])
    _ = try call(#"{"action":"state.record","state":{"cursors":[{"accountId":"a","receivedAt":"2026-09-11T17:00:00+08:00"}]}}"#)
    XCTAssertEqual(try store.summary(), before)
    // Seed legacy orphan state directly in this temporary test database only.
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("state.sqlite").path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(sqlite3_exec(db, "INSERT INTO cursors VALUES ('ghost','2026-09-01T00:00:00Z','test'),('disabled','2026-09-01T00:00:00Z','test');", nil, nil, nil), SQLITE_OK)
    let seeded = try store.summary()
    XCTAssertThrowsError(try call(#"{"action":"state.repair","accountIds":["ghost"]}"#))
    for ids in [#"["ghost","a"]"#, #"["ghost","disabled"]"#, #"["ghost","missing"]"#] {
      XCTAssertThrowsError(try call("{\"action\":\"state.repair\",\"confirmed\":true,\"accountIds\":\(ids)}"))
      XCTAssertEqual(try store.summary(), seeded)
    }
    _ = try call(#"{"action":"state.repair","confirmed":true,"accountIds":["ghost"]}"#)
    XCTAssertEqual(try store.summary().cursors.map(\.accountId), ["a", "disabled"])
  }

  func testCandidatesRulesDeduplicationAndFlagGate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    let service = MailBridgeService(store: store, accountProvider: { [MailAccount(id: "a", name: "A", enabled: true)] })
    func call(_ json: String) throws -> BridgeResponse {
      try service.handle(JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8)))
    }
    _ = try call(#"{"action":"state.record","state":{"processed":[{"ref":{"accountId":"a","libraryId":1},"fingerprint":"f","receivedAt":"2026-09-11T10:00:00Z","category":"information"}],"candidates":[{"id":"T-1","kind":"reminder","title":"test","accountId":"a","libraryId":1,"sourceSubject":"test"}]}}"#)
    XCTAssertTrue(try store.isProcessed(MessageRef(accountId: "a", libraryId: 1), fingerprint: "f"))
    XCTAssertNil(try store.pendingCandidates().first?.due)
    let before = try store.summary()
    XCTAssertThrowsError(try call(#"{"action":"state.record","state":{"processed":[{"ref":{"accountId":"a","libraryId":2},"fingerprint":"f","receivedAt":"2026-09-11T10:00:00Z","category":"information"}],"shadowRunsCompleted":9}}"#))
    XCTAssertEqual(try store.summary(), before)
    XCTAssertThrowsError(try call(#"{"action":"state.record","state":{"flaggingEnabled":true}}"#))
    _ = try call(#"{"action":"state.record","confirmed":true,"state":{"flaggingEnabled":true}}"#)
    XCTAssertTrue(try store.summary().flaggingEnabled)
    XCTAssertThrowsError(try call(#"{"action":"candidate.resolve","candidateIds":["T-1"],"candidateStatus":"dismissed"}"#))
    _ = try call(#"{"action":"candidate.resolve","confirmed":true,"candidateIds":["T-1"],"candidateStatus":"dismissed"}"#)
    XCTAssertEqual(try store.pendingCandidates(), [])
    XCTAssertThrowsError(try call(#"{"action":"rule.upsert","rule":{"field":"domain","pattern":"example.edu","category":"information"}}"#))
    _ = try call(#"{"action":"rule.upsert","confirmed":true,"rule":{"field":"domain","pattern":"example.edu","category":"information"}}"#)
    XCTAssertEqual(try store.rules().count, 1)
  }

  func testScanRawPagesAndFailedPage() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    func message(_ id: Int64, _ receivedAt: String) -> MailMessage {
      MailMessage(
        ref: MessageRef(accountId: "a", libraryId: id), accountName: "Synthetic",
        mailboxName: "Inbox", receivedAt: receivedAt, sender: "demo@example.test",
        subject: "Synthetic \(id)", sanitizedText: nil, isRead: false, flagIndex: -1,
        attachmentCount: 0, attachments: nil, fingerprint: "synthetic-\(id)", hint: .information
      )
    }
    // Mail's raw enumeration is intentionally not chronological; IDs 4 and 5 tie.
    let raw = [message(1, "2026-09-11T10:00:00Z"), message(2, "2026-09-13T10:00:00Z"),
               message(3, "2026-09-15T10:00:00Z"), message(4, "2026-09-13T10:00:00Z"),
               message(5, "2026-09-13T10:00:00Z")]
    let account = { [MailAccount(id: "a", name: "Synthetic", enabled: true)] }
    let service = MailBridgeService(store: store, accountProvider: account, scanProvider: { since, until, offset, limit, preview in
      XCTAssertEqual(DateCodec.string(since), "2026-09-10T00:00:00.000Z")
      XCTAssertEqual(DateCodec.string(until), "2026-09-16T00:00:00.000Z")
      XCTAssertEqual(limit, 3)
      XCTAssertEqual(preview, 0)
      return Array(raw.dropFirst(offset).prefix(limit))
    })
    func page(_ service: MailBridgeService, _ offset: Int) throws -> BridgeResponse {
      let json = "{\"action\":\"message.scan\",\"since\":\"2026-09-10T00:00:00Z\",\"until\":\"2026-09-16T00:00:00Z\",\"offset\":\(offset),\"limit\":2,\"previewCharacters\":0}"
      return try service.handle(JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8)))
    }
    let first = try page(service, 0)
    XCTAssertEqual(first.messages?.map(\.ref.libraryId), [2, 1])
    XCTAssertEqual(first.details?["nextOffset"], "2")
    XCTAssertEqual(first.details?["hasMore"], "true")
    let second = try page(service, 2)
    XCTAssertEqual(second.messages?.map(\.ref.libraryId), [3, 4])
    XCTAssertEqual(second.details?["nextOffset"], "4")
    let last = try page(service, 4)
    XCTAssertEqual(last.messages?.map(\.ref.libraryId), [5])
    XCTAssertEqual(last.details?["nextOffset"], "5")
    XCTAssertEqual(last.details?["hasMore"], "false")
    XCTAssertEqual(try store.summary().cursors, [])

    let failing = MailBridgeService(store: store, accountProvider: account, scanProvider: { _, _, offset, limit, _ in
      if offset == 2 { throw MailBridgeError.mailAutomation("synthetic parse failure") }
      return Array(raw.dropFirst(offset).prefix(limit))
    })
    XCTAssertEqual(try page(failing, 0).details?["nextOffset"], "2")
    XCTAssertThrowsError(try page(failing, 2))
    XCTAssertEqual(try store.summary().cursors, [])

    // Processed records are filtered after slicing and cannot shrink the raw offset.
    func call(_ json: String) throws -> BridgeResponse {
      try service.handle(JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8)))
    }
    _ = try call(#"{"action":"state.record","state":{"processed":[{"ref":{"accountId":"a","libraryId":2},"fingerprint":"synthetic-2","receivedAt":"2026-09-13T10:00:00Z","category":"information"}]}}"#)
    XCTAssertEqual(try page(service, 0).messages?.map(\.ref.libraryId), [1])
    XCTAssertEqual(try page(service, 0).details?["nextOffset"], "2")
    XCTAssertEqual(try page(service, 2).messages?.map(\.ref.libraryId), [3, 4])
  }

  func testCandidateReplayAndBindingRollback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    let service = MailBridgeService(store: store, accountProvider: {
      [MailAccount(id: "a", name: "Synthetic", enabled: true)]
    })
    func call(_ json: String) throws -> BridgeResponse {
      try service.handle(JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8)))
    }
    func candidate(_ id: String, _ libraryId: Int64, _ title: String) -> String {
      "{\"id\":\"\(id)\",\"kind\":\"reminder\",\"title\":\"\(title)\",\"accountId\":\"a\",\"libraryId\":\(libraryId),\"sourceSubject\":\"Synthetic\"}"
    }
    _ = try call("{\"action\":\"state.record\",\"state\":{\"candidates\":[\(candidate("T-1", 1, "Original")),\(candidate("T-2", 2, "Original"))]}}")
    _ = try call(#"{"action":"candidate.resolve","confirmed":true,"candidateIds":["T-1"],"candidateStatus":"accepted"}"#)
    _ = try call(#"{"action":"candidate.resolve","confirmed":true,"candidateIds":["T-2"],"candidateStatus":"dismissed"}"#)
    XCTAssertEqual(try store.pendingCandidates(), [])
    _ = try call("{\"action\":\"state.record\",\"state\":{\"candidates\":[\(candidate("T-1", 1, "Replay")),\(candidate("T-2", 2, "Replay"))]}}")
    XCTAssertEqual(try store.pendingCandidates(), [])

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("state.sqlite").path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    func snapshot(_ id: String) -> [String] {
      var statement: OpaquePointer?
      XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT status, title FROM candidates WHERE id = ?", -1, &statement, nil), SQLITE_OK)
      defer { sqlite3_finalize(statement) }
      XCTAssertEqual(sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)), SQLITE_OK)
      XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
      return (0...1).map { String(cString: sqlite3_column_text(statement, Int32($0))) }
    }
    XCTAssertEqual(snapshot("T-1"), ["accepted", "Original"])
    XCTAssertEqual(snapshot("T-2"), ["dismissed", "Original"])
    let before = try store.summary()
    let collision = "{\"action\":\"state.record\",\"state\":{\"candidates\":[\(candidate("T-3", 3, "New")),\(candidate("T-1", 99, "Wrong source"))],\"cursors\":[{\"accountId\":\"a\",\"receivedAt\":\"2026-09-16T00:00:00Z\"}]}}"
    XCTAssertThrowsError(try call(collision))
    XCTAssertEqual(try store.summary(), before)
    XCTAssertEqual(snapshot("T-1"), ["accepted", "Original"])
    XCTAssertThrowsError(try call(#"{"action":"state.record","state":{"candidates":[{"id":"T-1","kind":"reminder","title":"Replay","accountId":"a","libraryId":1,"sourceSubject":"Synthetic","status":"accepted"}],"shadowRunsCompleted":42}}"#))
    XCTAssertEqual(try store.summary(), before)
    _ = try call(#"{"action":"candidate.resolve","confirmed":true,"candidateIds":["T-1"],"candidateStatus":"pending"}"#)
    XCTAssertEqual(try store.pendingCandidates().map(\.id), ["T-1"])
    _ = try call("{\"action\":\"state.record\",\"state\":{\"candidates\":[\(candidate("T-1", 1, "Updated after reopen"))]}}")
    XCTAssertEqual(snapshot("T-1"), ["pending", "Updated after reopen"])
    XCTAssertEqual(snapshot("T-2"), ["dismissed", "Original"])
  }
}

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) { precondition(actual == expected, "Expected \(expected), got \(actual)") }
func XCTAssertTrue(_ value: Bool) { precondition(value) }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T) {
  do { _ = try body(); preconditionFailure("Expected rejection") } catch {}
}

@main struct SyntheticTestMain {
  static func main() throws {
    let suite = MailBridgeTests()
    suite.testAttachmentPolicy()
    try suite.testStateAtomicityAndRepair()
    try suite.testCandidatesRulesDeduplicationAndFlagGate()
    try suite.testScanRawPagesAndFailedPage()
    try suite.testCandidateReplayAndBindingRollback()
    print("Synthetic attachment, account/repair, scan paging, and candidate replay checks passed")
  }
}
