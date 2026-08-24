import CTurso
import Foundation

/// A prepared SQL statement. Parameter positions are one-based, matching SQLite.
public actor Statement {
  private let native: NativeStatement
  private let gate: AsyncMutex
  private let syncDriver: SyncIODriver?
  private var finalized = false

  internal init(
    native: NativeStatement,
    gate: AsyncMutex,
    syncDriver: SyncIODriver?
  ) {
    self.native = native
    self.gate = gate
    self.syncDriver = syncDriver
  }

  public var parameterCount: Int {
    get throws {
      let count = turso_statement_parameters_count(native.pointer)
      guard count >= 0 else {
        throw TursoError.internalError("Unable to read statement parameter count.")
      }
      return Int(count)
    }
  }

  public func bind(_ values: [Value]) async throws {
    let expected = try parameterCount
    guard values.count == expected else {
      throw TursoError.invalidArgument(
        "Statement expects \(expected) parameters, but \(values.count) were supplied."
      )
    }
    for (offset, value) in values.enumerated() {
      try await bind(value, at: offset + 1)
    }
  }

  public func bind(_ value: Value, at position: Int) async throws {
    guard position > 0 else {
      throw TursoError.invalidArgument("Statement parameter positions are one-based.")
    }
    try await gate.withLock { [native] in
      try Task.checkCancellation()
      let status: turso_status_code_t
      switch value {
      case .null:
        status = turso_statement_bind_positional_null(native.pointer, position)
      case .integer(let value):
        status = turso_statement_bind_positional_int(native.pointer, position, value)
      case .real(let value):
        status = turso_statement_bind_positional_double(native.pointer, position, value)
      case .text(let value):
        status = value.withCString { pointer in
          turso_statement_bind_positional_text(
            native.pointer,
            position,
            pointer,
            value.utf8.count
          )
        }
      case .blob(let value):
        status = value.withUnsafeBytes { bytes in
          turso_statement_bind_positional_blob(
            native.pointer,
            position,
            bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
            bytes.count
          )
        }
      }
      try NativeStatus.check(status)
    }
  }

  /// Executes a non-row-producing statement and returns its affected-row count.
  @discardableResult
  public func execute() async throws -> Int64 {
    try await gate.withLock { [native, syncDriver] in
      while true {
        try Task.checkCancellation()
        var changes: UInt64 = 0
        let status = try NativeStatus.call(
          allowing: [NativeStatus.done, NativeStatus.io]
        ) {
          turso_statement_execute(native.pointer, &changes, $0)
        }
        if status == NativeStatus.done {
          return Int64(clamping: changes)
        }
        if let syncDriver {
          try await syncDriver.processOneIO()
        }
        try NativeStatus.call {
          turso_statement_run_io(native.pointer, $0)
        }
        await Task.yield()
      }
    }
  }

  /// Advances the statement and returns an owned row, or `nil` at completion.
  public func step() async throws -> Row? {
    try await gate.withLock { [native, syncDriver] in
      while true {
        try Task.checkCancellation()
        let status = try NativeStatus.call(
          allowing: [NativeStatus.done, NativeStatus.row, NativeStatus.io]
        ) {
          turso_statement_step(native.pointer, $0)
        }
        switch status {
        case NativeStatus.done:
          return nil
        case NativeStatus.row:
          return try Self.copyCurrentRow(from: native.pointer)
        case NativeStatus.io:
          if let syncDriver {
            try await syncDriver.processOneIO()
          }
          try NativeStatus.call {
            turso_statement_run_io(native.pointer, $0)
          }
          await Task.yield()
        default:
          throw TursoError.internalError("Unexpected statement status \(status).")
        }
      }
    }
  }

  public func allRows() async throws -> [Row] {
    var rows: [Row] = []
    while let row = try await step() {
      rows.append(row)
    }
    return rows
  }

  public func reset() async throws {
    try await gate.withLock { [native] in
      try NativeStatus.call { turso_statement_reset(native.pointer, $0) }
    }
  }

  public func finalize() async throws {
    guard !finalized else { return }
    try await gate.withLock { [native, syncDriver] in
      while true {
        let status = try NativeStatus.call(
          allowing: [NativeStatus.ok, NativeStatus.done, NativeStatus.io]
        ) {
          turso_statement_finalize(native.pointer, $0)
        }
        guard status == NativeStatus.io else { return }
        if let syncDriver {
          try await syncDriver.processOneIO()
        }
        try NativeStatus.call {
          turso_statement_run_io(native.pointer, $0)
        }
      }
    }
    finalized = true
  }

  private static func copyCurrentRow(from statement: OpaquePointer) throws -> Row {
    let count = turso_statement_column_count(statement)
    guard count >= 0 else {
      throw TursoError.internalError("Unable to read result column count.")
    }

    var names: [String] = []
    var values: [Value] = []
    names.reserveCapacity(Int(count))
    values.reserveCapacity(Int(count))

    for index in 0..<Int(count) {
      if let namePointer = turso_statement_column_name(statement, index) {
        names.append(String(cString: namePointer))
        turso_str_deinit(namePointer)
      } else {
        names.append("")
      }

      switch turso_statement_row_value_kind(statement, index).rawValue {
      case UInt32(TURSO_TYPE_NULL.rawValue):
        values.append(.null)
      case UInt32(TURSO_TYPE_INTEGER.rawValue):
        values.append(.integer(turso_statement_row_value_int(statement, index)))
      case UInt32(TURSO_TYPE_REAL.rawValue):
        values.append(.real(turso_statement_row_value_double(statement, index)))
      case UInt32(TURSO_TYPE_TEXT.rawValue), UInt32(TURSO_TYPE_BLOB.rawValue):
        let byteCount = turso_statement_row_value_bytes_count(statement, index)
        guard byteCount >= 0 else {
          throw TursoError.internalError("Turso returned an invalid value length.")
        }
        let data: Data
        if byteCount == 0 {
          data = Data()
        } else if let pointer = turso_statement_row_value_bytes_ptr(statement, index) {
          data = Data(bytes: pointer, count: Int(byteCount))
        } else {
          throw TursoError.internalError("Turso returned a null value pointer.")
        }
        if turso_statement_row_value_kind(statement, index).rawValue == TURSO_TYPE_TEXT.rawValue {
          values.append(.text(String(decoding: data, as: UTF8.self)))
        } else {
          values.append(.blob(data))
        }
      default:
        throw TursoError.internalError("Turso returned an unknown value type.")
      }
    }
    return Row(columnNames: names, values: values)
  }
}
