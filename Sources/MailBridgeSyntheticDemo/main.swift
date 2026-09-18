import Foundation
import MailBridgeCore
import MailBridgeRuntime

@main struct MailBridgeSyntheticDemo {
  static func main() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MailBridgeSyntheticDemo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try StateStore(directory: directory)
    func message(_ id: Int64, _ receivedAt: String) -> MailMessage {
      MailMessage(
        ref: MessageRef(accountId: "demo", libraryId: id), accountName: "Synthetic",
        mailboxName: "Inbox", receivedAt: receivedAt, sender: "demo@example.test",
        subject: "Synthetic item \(id)", sanitizedText: nil, isRead: false, flagIndex: -1,
        attachmentCount: 0, attachments: nil, fingerprint: "demo-\(id)", hint: .information
      )
    }
    // Deliberately unordered, like an inbox enumeration; no Apple Mail call is made.
    let inbox = [message(1, "2026-09-11T10:00:00Z"),
                 message(2, "2026-09-13T10:00:00Z"),
                 message(3, "2026-09-15T10:00:00Z")]
    let service = MailBridgeService(
      store: store,
      accountProvider: { [MailAccount(id: "demo", name: "Synthetic", enabled: true)] },
      scanProvider: { _, _, offset, limit, _ in Array(inbox.dropFirst(offset).prefix(limit)) }
    )
    func call(_ request: String) throws -> BridgeResponse {
      try service.handle(JSONDecoder().decode(BridgeRequest.self, from: Data(request.utf8)))
    }

    var offset = 0
    var seen: [Int64] = []
    repeat {
      let page = try call("{\"action\":\"message.scan\",\"since\":\"2026-09-10T00:00:00Z\",\"until\":\"2026-09-16T00:00:00Z\",\"limit\":2,\"previewCharacters\":0,\"offset\":\(offset)}")
      let ids = (page.messages ?? []).map(\.ref.libraryId)
      seen.append(contentsOf: ids)
      print("scan offset=\(offset) displayed=\(ids) nextOffset=\(page.details?["nextOffset"] ?? "?") hasMore=\(page.details?["hasMore"] ?? "?")")
      guard let next = page.details?["nextOffset"].flatMap(Int.init), next > offset else {
        throw MailBridgeError.invalidRequest("Synthetic page did not advance")
      }
      offset = next
      if page.details?["hasMore"] == "false" { break }
    } while true
    guard Set(seen) == Set([1, 2, 3]) else {
      throw MailBridgeError.invalidRequest("Synthetic scan missed an item")
    }

    let record = #"{"action":"state.record","state":{"processed":[{"ref":{"accountId":"demo","libraryId":1},"fingerprint":"demo-1","receivedAt":"2026-09-11T10:00:00Z","category":"information"},{"ref":{"accountId":"demo","libraryId":2},"fingerprint":"demo-2","receivedAt":"2026-09-13T10:00:00Z","category":"information"},{"ref":{"accountId":"demo","libraryId":3},"fingerprint":"demo-3","receivedAt":"2026-09-15T10:00:00Z","category":"action","candidateId":"T-DEMO"}],"candidates":[{"id":"T-DEMO","kind":"reminder","title":"Review synthetic item","accountId":"demo","libraryId":3,"sourceSubject":"Synthetic item 3"}],"cursors":[{"accountId":"demo","receivedAt":"2026-09-15T10:00:00Z"}]}}"#
    let recorded = try call(record)
    print("state.record processed=\(recorded.state?.processedCount ?? -1) pending=\(recorded.state?.pendingCandidateCount ?? -1) cursor=\(recorded.state?.cursors.first?.receivedAt ?? "?")")
    _ = try call(#"{"action":"candidate.resolve","confirmed":true,"candidateIds":["T-DEMO"],"candidateStatus":"accepted"}"#)
    let replay = try call(record)
    print("replay pending=\(replay.state?.pendingCandidateCount ?? -1) processed=\(replay.state?.processedCount ?? -1)")
    guard replay.state?.pendingCandidateCount == 0,
      try call(#"{"action":"state.pending"}"#).candidates?.isEmpty == true else {
      throw MailBridgeError.storage("Replay reopened a resolved synthetic candidate")
    }
    print("synthetic workflow passed (temporary SQLite removed on exit)")
  }
}
