import CTurso
import Foundation

public enum TursoError: Error, Sendable, Equatable {
  case invalidArgument(String)
  case syncNotConfigured
  case cancelled
  case network(String)
  case fileSystem(String)
  case database(code: UInt32, message: String)
  case internalError(String)
}

extension TursoError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidArgument(let message), .network(let message),
      .fileSystem(let message), .internalError(let message):
      message
    case .syncNotConfigured:
      "This database was opened without sync configuration."
    case .cancelled:
      "The operation was cancelled."
    case .database(let code, let message):
      message.isEmpty ? "Turso error \(code)" : message
    }
  }
}

internal enum NativeStatus {
  static let ok: UInt32 = 0
  static let done: UInt32 = 1
  static let row: UInt32 = 2
  static let io: UInt32 = 3

  @discardableResult
  static func call(
    allowing allowed: Set<UInt32> = [ok],
    _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> turso_status_code_t
  ) throws -> UInt32 {
    var errorPointer: UnsafePointer<CChar>?
    let status = body(&errorPointer).rawValue
    let message: String
    if let errorPointer {
      message = String(cString: errorPointer)
      turso_str_deinit(errorPointer)
    } else {
      message = ""
    }
    guard allowed.contains(status) else {
      throw TursoError.database(code: status, message: message)
    }
    return status
  }

  static func check(_ status: turso_status_code_t) throws {
    let code = status.rawValue
    guard code == ok else {
      throw TursoError.database(code: code, message: "")
    }
  }
}
