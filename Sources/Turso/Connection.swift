import CTurso
import Foundation

/// A serialized connection to a Turso database.
public actor Connection {
  private let native: NativeConnection
  private let gate = AsyncMutex()
  private let syncDriver: SyncIODriver?

  internal init(native: NativeConnection, syncDriver: SyncIODriver?) {
    self.native = native
    self.syncDriver = syncDriver
  }

  public var isAutocommit: Bool {
    turso_connection_get_autocommit(native.pointer)
  }

  public var lastInsertRowID: Int64 {
    turso_connection_last_insert_rowid(native.pointer)
  }

  public func setBusyTimeout(milliseconds: Int64) {
    turso_connection_set_busy_timeout_ms(native.pointer, milliseconds)
  }

  public func prepare(_ sql: String) async throws -> Statement {
    guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TursoError.invalidArgument("SQL must not be empty.")
    }
    return try await gate.withLock { [native, gate, syncDriver] in
      var statementPointer: OpaquePointer?
      _ = try sql.withCString { sqlPointer in
        try NativeStatus.call {
          turso_connection_prepare_single(
            native.pointer,
            sqlPointer,
            &statementPointer,
            $0
          )
        }
      }
      guard let statementPointer else {
        throw TursoError.internalError("Turso did not return a statement handle.")
      }
      return Statement(
        native: NativeStatement(statementPointer, owner: native),
        gate: gate,
        syncDriver: syncDriver
      )
    }
  }

  @discardableResult
  public func execute(_ sql: String, _ arguments: [Value] = []) async throws -> Int64 {
    let statement = try await prepare(sql)
    do {
      try await statement.bind(arguments)
      let changes = try await statement.execute()
      try await statement.finalize()
      return changes
    } catch {
      try? await statement.finalize()
      throw error
    }
  }

  public func query(_ sql: String, _ arguments: [Value] = []) async throws -> [Row] {
    let statement = try await prepare(sql)
    do {
      try await statement.bind(arguments)
      let rows = try await statement.allRows()
      try await statement.finalize()
      return rows
    } catch {
      try? await statement.finalize()
      throw error
    }
  }
}
