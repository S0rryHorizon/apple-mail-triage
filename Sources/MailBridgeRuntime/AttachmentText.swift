import Foundation
import MailBridgeCore

enum AttachmentText {
  static func extract(path: String, limit: Int) throws -> (String, Bool) {
    let process = Process()
    let defaultPython = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/MailTriage/converter/bin/python").path
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MAIL_TRIAGE_CONVERTER_PYTHON"] ?? defaultPython)
    guard FileManager.default.isExecutableFile(atPath: process.executableURL!.path) else {
      throw MailBridgeError.attachmentRejected("附件文字转换器尚未安装；请运行 scripts/install-converter.sh。")
    }
    process.arguments = ["-I", "-B", "-c", worker, path, String(limit)]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = result["text"] as? String, let truncated = result["truncated"] as? Bool else {
      throw MailBridgeError.attachmentRejected("附件文字提取失败、超时或无可提取文字；临时附件已进入清理流程。")
    }
    return (PrivacyFilter.sanitize(text, limit: limit), truncated)
  }

  static let worker = #"""
import sys, signal, json, re, zipfile
from pathlib import Path
signal.alarm(25)
def audit(event, args):
    if event == 'socket.connect':
        raise PermissionError('Offline attachment conversion')
sys.addaudithook(audit)
path = Path(sys.argv[1])
limit = int(sys.argv[2])
if path.stat().st_size > 10 * 1024 * 1024:
    raise ValueError('Attachment size exceeds policy')
extension = path.suffix.lower()
if extension in ('.txt', '.md', '.csv', '.tsv'):
    from charset_normalizer import from_bytes
    decoded = from_bytes(path.read_bytes()).best()
    if decoded is None:
        raise ValueError('Unknown text encoding')
    text = str(decoded)
elif extension in ('.pdf', '.docx', '.xlsx'):
    if extension in ('.docx', '.xlsx'):
        with zipfile.ZipFile(path) as container:
            entries = container.infolist()
            if len(entries) > 5000 or sum(item.file_size for item in entries) > 64 * 1024 * 1024:
                raise ValueError('Expanded document exceeds policy')
            if any('vbaproject' in item.filename.lower() for item in entries):
                raise ValueError('Macro content is not allowed')
    from markitdown import StreamInfo
    from markitdown.converters import PdfConverter, DocxConverter, XlsxConverter
    converter = {'.pdf': PdfConverter, '.docx': DocxConverter, '.xlsx': XlsxConverter}[extension]()
    with path.open('rb') as source:
        text = converter.convert(source, StreamInfo(extension=extension)).markdown
else:
    raise ValueError('Use image inspection for images; no automatic OCR or cloud calls')
text = re.sub(r'!\[[^\]]*\]\(data:[^)]+\)', '[embedded image omitted]', text)
if not text.strip():
    raise ValueError('No text; visual inspection or OCR is required')
print(json.dumps({'text': text[:limit], 'truncated': len(text) > limit}, ensure_ascii=False))
"""#
}
