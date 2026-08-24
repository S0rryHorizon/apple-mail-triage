import Foundation
import MailBridgeCore
import SQLite3

struct FlagAuditOperation {
  var ref: MessageRef
  var previousFlagIndex: Int
  var resultingFlagIndex: Int
  var requestedColor: String
}

final class StateStore {
  private var db: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init() throws {
    let manager = FileManager.default
    let base: URL
    if let override = ProcessInfo.processInfo.environment["MAIL_TRIAGE_STATE_DIR"], !override.isEmpty {
      base = URL(fileURLWithPath: override, isDirectory: true)
    } else {
      base = try manager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      ).appendingPathComponent("MailTriage", isDirectory: true)
    }
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    let path = base.appendingPathComponent("state.sqlite").path
    guard sqlite3_open(path, &db) == SQLITE_OK else {
      throw MailBridgeError.storage("无法打开本地状态数据库：\(lastError)")
    }
    try execute("PRAGMA journal_mode=WAL;")
    try execute("PRAGMA foreign_keys=ON;")
    try migrate()
  }

  deinit { sqlite3_close(db) }

  private func migrate() throws {
    try execute(
      """
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS cursors (
        account_id TEXT PRIMARY KEY,
        received_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS processed_messages (
        account_id TEXT NOT NULL,
        library_id INTEGER NOT NULL,
        fingerprint TEXT NOT NULL,
        received_at TEXT NOT NULL,
        category TEXT NOT NULL,
        candidate_id TEXT,
        processed_at TEXT NOT NULL,
        PRIMARY KEY(account_id, library_id)
      );
      CREATE UNIQUE INDEX IF NOT EXISTS processed_fingerprint
        ON processed_messages(fingerprint);
      CREATE TABLE IF NOT EXISTS candidates (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        start_at TEXT,
        end_at TEXT,
        due_at TEXT,
        location TEXT,
        notes TEXT,
        account_id TEXT NOT NULL,
        library_id INTEGER NOT NULL,
        source_subject TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS explicit_rules (
        id TEXT PRIMARY KEY,
        field TEXT NOT NULL,
        pattern TEXT NOT NULL,
        category TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(field, pattern)
      );
      CREATE TABLE IF NOT EXISTS flag_batches (
        id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        rolled_back INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS flag_operations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        batch_id TEXT NOT NULL REFERENCES flag_batches(id),
        account_id TEXT NOT NULL,
        library_id INTEGER NOT NULL,
        message_id TEXT,
        requested_color TEXT NOT NULL,
        previous_flag_index INTEGER NOT NULL,
        resulting_flag_index INTEGER NOT NULL,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS temp_exports (
        token TEXT PRIMARY KEY,
        path TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
      """)
    try setDefault(key: "shadow_runs_completed", value: "0")
    try setDefault(key: "flagging_enabled", value: "false")
  }

  func summary() throws -> StateSummary {
    let processedCount = try scalarInt("SELECT COUNT(*) FROM processed_messages;")
    let pendingCount = try scalarInt("SELECT COUNT(*) FROM candidates WHERE status = 'pending';")
    let cursors = try withStatement(
      "SELECT account_id, received_at FROM cursors ORDER BY account_id;"
    ) { statement in
      var result: [CursorRecord] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(CursorRecord(accountId: text(statement, 0) ?? "", receivedAt: text(statement, 1) ?? ""))
      }
      return result
    }
    return StateSummary(
      processedCount: processedCount,
      pendingCandidateCount: pendingCount,
      cursors: cursors,
      shadowRunsCompleted: Int(try setting("shadow_runs_completed") ?? "0") ?? 0,
      flaggingEnabled: (try setting("flagging_enabled") ?? "false") == "true"
    )
  }

  func record(_ update: StateUpdate) throws {
    try transaction {
      let now = DateCodec.string(Date())
      for record in update.processed ?? [] {
        try withStatement(
          """
          INSERT INTO processed_messages(
            account_id, library_id, fingerprint, received_at, category, candidate_id, processed_at
          ) VALUES(?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(account_id, library_id) DO UPDATE SET
            fingerprint=excluded.fingerprint,
            received_at=excluded.received_at,
            category=excluded.category,
            candidate_id=excluded.candidate_id,
            processed_at=excluded.processed_at;
          """
        ) { statement in
          bind(record.ref.accountId, 1, statement)
          sqlite3_bind_int64(statement, 2, record.ref.libraryId)
          bind(record.fingerprint, 3, statement)
          bind(record.receivedAt, 4, statement)
          bind(record.category.rawValue, 5, statement)
          bind(record.candidateId, 6, statement)
          bind(now, 7, statement)
          try stepDone(statement)
        }
      }
      for candidate in update.candidates ?? [] { try upsertCandidate(candidate, now: now) }
      for cursor in update.cursors ?? [] {
        try withStatement(
          """
          INSERT INTO cursors(account_id, received_at, updated_at) VALUES(?, ?, ?)
          ON CONFLICT(account_id) DO UPDATE SET
            received_at = CASE
              WHEN excluded.received_at > cursors.received_at THEN excluded.received_at
              ELSE cursors.received_at
            END,
            updated_at=excluded.updated_at;
          """
        ) { statement in
          bind(cursor.accountId, 1, statement)
          bind(cursor.receivedAt, 2, statement)
          bind(now, 3, statement)
          try stepDone(statement)
        }
      }
      if let count = update.shadowRunsCompleted {
        try setSetting("shadow_runs_completed", String(max(0, count)))
      }
      if let enabled = update.flaggingEnabled {
        try setSetting("flagging_enabled", enabled ? "true" : "false")
      }
    }
  }

  func isProcessed(_ ref: MessageRef, fingerprint: String) throws -> Bool {
    try withStatement(
      "SELECT 1 FROM processed_messages WHERE (account_id = ? AND library_id = ?) OR fingerprint = ? LIMIT 1;"
    ) { statement in
      bind(ref.accountId, 1, statement)
      sqlite3_bind_int64(statement, 2, ref.libraryId)
      bind(fingerprint, 3, statement)
      return sqlite3_step(statement) == SQLITE_ROW
    }
  }

  func pendingCandidates() throws -> [CandidateRecord] {
    try withStatement(
      """
      SELECT id, kind, title, start_at, end_at, due_at, location, notes,
             account_id, library_id, source_subject, status
      FROM candidates WHERE status = 'pending' ORDER BY created_at;
      """
    ) { statement in
      var result: [CandidateRecord] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let kindText = text(statement, 1), let kind = CandidateKind(rawValue: kindText) else { continue }
        result.append(
          CandidateRecord(
            id: text(statement, 0) ?? "",
            kind: kind,
            title: text(statement, 2) ?? "",
            start: text(statement, 3),
            end: text(statement, 4),
            due: text(statement, 5),
            location: text(statement, 6),
            notes: text(statement, 7),
            accountId: text(statement, 8) ?? "",
            libraryId: sqlite3_column_int64(statement, 9),
            sourceSubject: text(statement, 10) ?? "",
            status: text(statement, 11)
          ))
      }
      return result
    }
  }

  func resolveCandidates(ids: [String], status: String) throws {
    guard ["accepted", "dismissed", "pending"].contains(status) else {
      throw MailBridgeError.invalidRequest("候选状态仅支持 accepted、dismissed 或 pending。")
    }
    try transaction {
      for id in ids {
        try withStatement("UPDATE candidates SET status = ?, updated_at = ? WHERE id = ?;") { statement in
          bind(status, 1, statement)
          bind(DateCodec.string(Date()), 2, statement)
          bind(id, 3, statement)
          try stepDone(statement)
        }
      }
    }
  }

  func rules() throws -> [ExplicitRule] {
    try withStatement(
      "SELECT id, field, pattern, category, enabled FROM explicit_rules ORDER BY created_at;"
    ) { statement in
      var result: [ExplicitRule] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        guard let categoryText = text(statement, 3), let category = TriageCategory(rawValue: categoryText) else { continue }
        result.append(
          ExplicitRule(
            id: text(statement, 0),
            field: text(statement, 1) ?? "",
            pattern: text(statement, 2) ?? "",
            category: category,
            enabled: sqlite3_column_int(statement, 4) != 0
          ))
      }
      return result
    }
  }

  func upsertRule(_ rule: ExplicitRule) throws -> ExplicitRule {
    guard ["sender", "domain", "subject"].contains(rule.field) else {
      throw MailBridgeError.invalidRequest("规则 field 仅支持 sender、domain 或 subject。")
    }
    guard !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MailBridgeError.invalidRequest("规则 pattern 不能为空。")
    }
    let id = rule.id ?? UUID().uuidString.lowercased()
    let now = DateCodec.string(Date())
    try withStatement(
      """
      INSERT INTO explicit_rules(id, field, pattern, category, enabled, created_at, updated_at)
      VALUES(?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(field, pattern) DO UPDATE SET
        category=excluded.category, enabled=excluded.enabled, updated_at=excluded.updated_at;
      """
    ) { statement in
      bind(id, 1, statement)
      bind(rule.field, 2, statement)
      bind(rule.pattern, 3, statement)
      bind(rule.category.rawValue, 4, statement)
      sqlite3_bind_int(statement, 5, rule.enabled == false ? 0 : 1)
      bind(now, 6, statement)
      bind(now, 7, statement)
      try stepDone(statement)
    }
    return ExplicitRule(
      id: id,
      field: rule.field,
      pattern: rule.pattern,
      category: rule.category,
      enabled: rule.enabled != false
    )
  }

  func beginFlagBatch(_ id: String) throws {
    try withStatement("INSERT INTO flag_batches(id, created_at) VALUES(?, ?);") { statement in
      bind(id, 1, statement)
      bind(DateCodec.string(Date()), 2, statement)
      try stepDone(statement)
    }
  }

  func recordFlag(batchId: String, operation: FlagAuditOperation) throws {
    try withStatement(
      """
      INSERT INTO flag_operations(
        batch_id, account_id, library_id, message_id, requested_color,
        previous_flag_index, resulting_flag_index, created_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?);
      """
    ) { statement in
      bind(batchId, 1, statement)
      bind(operation.ref.accountId, 2, statement)
      sqlite3_bind_int64(statement, 3, operation.ref.libraryId)
      bind(operation.ref.messageId, 4, statement)
      bind(operation.requestedColor, 5, statement)
      sqlite3_bind_int(statement, 6, Int32(operation.previousFlagIndex))
      sqlite3_bind_int(statement, 7, Int32(operation.resultingFlagIndex))
      bind(DateCodec.string(Date()), 8, statement)
      try stepDone(statement)
    }
  }

  func flagOperations(batchId: String) throws -> [FlagAuditOperation] {
    try withStatement(
      """
      SELECT account_id, library_id, message_id, requested_color,
             previous_flag_index, resulting_flag_index
      FROM flag_operations o JOIN flag_batches b ON b.id = o.batch_id
      WHERE o.batch_id = ? AND b.rolled_back = 0 ORDER BY o.id DESC;
      """
    ) { statement in
      bind(batchId, 1, statement)
      var result: [FlagAuditOperation] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        result.append(
          FlagAuditOperation(
            ref: MessageRef(
              accountId: text(statement, 0) ?? "",
              libraryId: sqlite3_column_int64(statement, 1),
              messageId: text(statement, 2)
            ),
            previousFlagIndex: Int(sqlite3_column_int(statement, 4)),
            resultingFlagIndex: Int(sqlite3_column_int(statement, 5)),
            requestedColor: text(statement, 3) ?? ""
          ))
      }
      return result
    }
  }

  func markFlagBatchRolledBack(_ id: String) throws {
    try withStatement("UPDATE flag_batches SET rolled_back = 1 WHERE id = ? AND rolled_back = 0;") { statement in
      bind(id, 1, statement)
      try stepDone(statement)
      guard sqlite3_changes(db) > 0 else {
        throw MailBridgeError.notFound("找不到可回滚的旗标批次：\(id)")
      }
    }
  }

  func registerExport(path: String) throws -> String {
    let token = UUID().uuidString.lowercased()
    try withStatement("INSERT INTO temp_exports(token, path, created_at) VALUES(?, ?, ?);") { statement in
      bind(token, 1, statement)
      bind(path, 2, statement)
      bind(DateCodec.string(Date()), 3, statement)
      try stepDone(statement)
    }
    return token
  }

  func exportPath(token: String) throws -> String {
    let value = try withStatement("SELECT path FROM temp_exports WHERE token = ?;") { statement in
      bind(token, 1, statement)
      return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }
    guard let value else { throw MailBridgeError.notFound("找不到临时附件令牌。") }
    return value
  }

  func removeExport(token: String) throws {
    try withStatement("DELETE FROM temp_exports WHERE token = ?;") { statement in
      bind(token, 1, statement)
      try stepDone(statement)
    }
  }

  private func upsertCandidate(_ candidate: CandidateRecord, now: String) throws {
    try withStatement(
      """
      INSERT INTO candidates(
        id, kind, title, start_at, end_at, due_at, location, notes,
        account_id, library_id, source_subject, status, created_at, updated_at
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        title=excluded.title, start_at=excluded.start_at, end_at=excluded.end_at,
        due_at=excluded.due_at, location=excluded.location, notes=excluded.notes,
        source_subject=excluded.source_subject, status=excluded.status, updated_at=excluded.updated_at;
      """
    ) { statement in
      bind(candidate.id, 1, statement)
      bind(candidate.kind.rawValue, 2, statement)
      bind(candidate.title, 3, statement)
      bind(candidate.start, 4, statement)
      bind(candidate.end, 5, statement)
      bind(candidate.due, 6, statement)
      bind(candidate.location, 7, statement)
      bind(candidate.notes, 8, statement)
      bind(candidate.accountId, 9, statement)
      sqlite3_bind_int64(statement, 10, candidate.libraryId)
      bind(candidate.sourceSubject, 11, statement)
      bind(candidate.status ?? "pending", 12, statement)
      bind(now, 13, statement)
      bind(now, 14, statement)
      try stepDone(statement)
    }
  }

  private func setting(_ key: String) throws -> String? {
    try withStatement("SELECT value FROM settings WHERE key = ?;") { statement in
      bind(key, 1, statement)
      return sqlite3_step(statement) == SQLITE_ROW ? text(statement, 0) : nil
    }
  }

  private func setDefault(key: String, value: String) throws {
    try withStatement("INSERT OR IGNORE INTO settings(key, value) VALUES(?, ?);") { statement in
      bind(key, 1, statement)
      bind(value, 2, statement)
      try stepDone(statement)
    }
  }

  private func setSetting(_ key: String, _ value: String) throws {
    try withStatement(
      "INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    ) { statement in
      bind(key, 1, statement)
      bind(value, 2, statement)
      try stepDone(statement)
    }
  }

  private func scalarInt(_ sql: String) throws -> Int {
    try withStatement(sql) { statement in
      guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
      return Int(sqlite3_column_int64(statement, 0))
    }
  }

  private func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE;")
    do {
      try body()
      try execute("COMMIT;")
    } catch {
      try? execute("ROLLBACK;")
      throw error
    }
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw MailBridgeError.storage(lastError)
    }
  }

  private func withStatement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw MailBridgeError.storage(lastError)
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
  }

  private func bind(_ value: String?, _ index: Int32, _ statement: OpaquePointer) {
    if let value {
      sqlite3_bind_text(statement, index, value, -1, transient)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }

  private func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw MailBridgeError.storage(lastError)
    }
  }

  private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard let pointer = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: pointer)
  }

  private var lastError: String {
    guard let db, let pointer = sqlite3_errmsg(db) else { return "未知 SQLite 错误" }
    return String(cString: pointer)
  }
}
