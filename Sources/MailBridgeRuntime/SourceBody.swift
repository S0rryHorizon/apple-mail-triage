import Foundation
import MailBridgeCore

/// Decode MIME using Python's standard library. Source stays in memory/pipes;
/// HTML is parsed as text without rendering, executing code, or loading URLs.
enum SourceBody {
  static func decode(_ source: String) throws -> String {
    // Raw MIME includes base64 attachments; export policy is unchanged.
    guard source.utf8.count <= 40 * 1024 * 1024 else {
      throw MailBridgeError.bodyUnavailable("source_size_limit")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-I", "-c", parser]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus == 65 {
      throw MailBridgeError.bodyUnavailable("source_body_missing")
    }
    guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
      throw MailBridgeError.bodyUnavailable("body_decode_failed")
    }
    return text
  }

  static let parser = #"""
import sys, signal
from email import policy
from email.parser import Parser
from html.parser import HTMLParser
signal.alarm(5)
message = Parser(policy=policy.default).parsestr(sys.stdin.read())
if (any(type(d).__name__ == 'StartBoundaryNotFoundDefect' for d in message.defects)
        and isinstance(message.get_payload(), str) and not message.get_payload().strip()):
    # Mail can expose only MIME headers while its rendered body is available.
    sys.exit(65)
body = message.get_body(preferencelist=('plain', 'html'))
if body is None or body.defects or message.defects:
    raise ValueError('No valid MIME body')
text = body.get_content(errors='strict')
if len(text.encode('utf-8')) > 10 * 1024 * 1024:
    raise ValueError('Decoded body exceeds limit')
if body.defects:
    raise ValueError('Invalid transfer encoding')
if body.get_content_type() == 'text/html':
    class Text(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.parts, self.hidden = [], 0
        def handle_starttag(self, tag, attrs):
            if tag in ('script', 'style', 'head'):
                self.hidden += 1
            if not self.hidden and tag in ('p', 'div', 'br', 'li', 'tr', 'h1', 'h2', 'h3'):
                self.parts.append('\n')
        def handle_endtag(self, tag):
            if tag in ('script', 'style', 'head') and self.hidden:
                self.hidden -= 1
            if not self.hidden and tag in ('p', 'div', 'li', 'tr'):
                self.parts.append('\n')
        def handle_data(self, data):
            if not self.hidden:
                self.parts.append(data)
    parser = Text()
    parser.feed(text)
    parser.close()
    text = ''.join(parser.parts)
sys.stdout.buffer.write(text.encode('utf-8'))
"""#
}
