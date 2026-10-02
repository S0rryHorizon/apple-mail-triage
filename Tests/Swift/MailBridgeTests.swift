import Foundation
import SQLite3
import MailBridgeCore

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
    let blocked = try JSONDecoder().decode(BridgeRequest.self, from: Data(#"{"action":"state.record","state":{"cursors":[]}}"#.utf8))
    XCTAssertThrowsError(try unavailable.handle(blocked))
    XCTAssertEqual(try store.summary(), before)
    for field in [
      #""processed":[{"ref":{"accountId":"ghost","libraryId":1},"fingerprint":"f","receivedAt":"2026-09-11T10:00:00Z","category":"information"}]"#,
      #""candidates":[{"id":"T-1","kind":"reminder","title":"test","accountId":"ghost","libraryId":1,"sourceSubject":"test"}]"#,
      #""cursors":[{"accountId":"ghost","receivedAt":"2026-09-12T10:00:00Z"}]"#,
      #""cursors":[{"accountId":"disabled","receivedAt":"2026-09-12T10:00:00Z"}]"#
    ] {
      XCTAssertThrowsError(try call("{\"action\":\"state.record\",\"state\":{\(field)}}"))
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

  func testCandidatesRulesAndDeduplication() throws {
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
    XCTAssertThrowsError(try call(#"{"action":"state.record","state":{"processed":[{"ref":{"accountId":"a","libraryId":2},"fingerprint":"f","receivedAt":"2026-09-11T10:00:00Z","category":"information"}]}}"#))
    XCTAssertEqual(try store.summary(), before)
    for action in ["flag.preview", "flag.commit", "flag.rollback"] {
      XCTAssertThrowsError(try service.handle(BridgeRequest(action: action)))
    }
    XCTAssertThrowsError(try call(#"{"action":"candidate.resolve","candidateIds":["T-1"],"candidateStatus":"dismissed"}"#))
    _ = try call(#"{"action":"candidate.resolve","confirmed":true,"candidateIds":["T-1"],"candidateStatus":"dismissed"}"#)
    XCTAssertEqual(try store.pendingCandidates(), [])
    XCTAssertThrowsError(try call(#"{"action":"rule.upsert","rule":{"field":"domain","pattern":"example.edu","category":"information"}}"#))
    _ = try call(#"{"action":"rule.upsert","confirmed":true,"rule":{"field":"domain","pattern":"example.edu","category":"information"}}"#)
    XCTAssertEqual(try store.rules().count, 1)
    for status in ["accepted", "dismissed"] {
      let candidate = "{\"id\":\"T-\(status)\",\"kind\":\"reminder\",\"title\":\"fixture\",\"accountId\":\"a\",\"libraryId\":1,\"sourceSubject\":\"fixture\"}"
      let insert = "{\"action\":\"state.record\",\"state\":{\"candidates\":[\(candidate)]}}"
      _ = try call(insert)
      _ = try call("{\"action\":\"candidate.resolve\",\"confirmed\":true,\"candidateIds\":[\"T-\(status)\"],\"candidateStatus\":\"\(status)\"}")
      _ = try call(insert)
      XCTAssertEqual(try store.pendingCandidates(), [])
    }
  }
}

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) { precondition(actual == expected, "Expected \(expected), got \(actual)") }
func XCTAssertTrue(_ value: Bool) { precondition(value) }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T) {
  do { _ = try body(); fatalError("Expected rejection") } catch {}
}
let suite = MailBridgeTests()
suite.testAttachmentPolicy()
try suite.testStateAtomicityAndRepair()
try suite.testCandidatesRulesAndDeduplication()
print("Attachment policy and service/storage integration checks passed")
