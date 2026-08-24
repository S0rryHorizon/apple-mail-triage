import Foundation
import MailBridgeCore

private func inputData() throws -> Data {
  let arguments = CommandLine.arguments
  if arguments.count == 3, arguments[1] == "--request" {
    return try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
  }
  if arguments.count == 2, arguments[1] == "--help" {
    let help = """
      MailBridge — Apple 邮件 JSON stdin/stdout interface

      Usage:
        echo '{"action":"status"}' | MailBridge
        MailBridge --request request.json

      Read: setup, status, message.scan, message.read, attachment.export/cleanup
      Flags: flag.preview, flag.commit, flag.rollback
      State: state.status, state.record, state.pending, candidate.resolve, rule.list/upsert
      """
    FileHandle.standardOutput.write(Data(help.utf8))
    exit(0)
  }
  let data = FileHandle.standardInput.readDataToEndOfFile()
  guard !data.isEmpty else {
    throw MailBridgeError.invalidRequest("请通过 stdin 或 --request 提供 JSON。")
  }
  return data
}

private func emit(_ response: BridgeResponse) {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  if let data = try? encoder.encode(response) {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}

do {
  let request = try JSONDecoder().decode(BridgeRequest.self, from: inputData())
  let service = try MailBridgeService()
  emit(try service.handle(request))
} catch {
  emit(BridgeResponse(ok: false, status: "error", message: String(describing: error)))
  exit(1)
}
