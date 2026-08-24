import CTurso
import Foundation

/// An embedded Turso database, optionally backed by Turso Cloud sync.
public final class Database: @unchecked Sendable {
  private let localDatabase: NativeDatabase?
  private let syncDriver: SyncIODriver?
  private let defaultConnection: Connection

  public let sync: SyncDatabase

  public static var version: String {
    guard let pointer = turso_version() else { return "unknown" }
    return String(cString: pointer)
  }

  public init(path: String, sync configuration: SyncConfiguration? = nil) async throws {
    guard !path.isEmpty else {
      throw TursoError.invalidArgument("Database path must not be empty.")
    }

    if let configuration {
      let driver = try SyncIODriver(path: path, configuration: configuration)
      try await driver.create()
      let nativeConnection = try await driver.connect()
      localDatabase = nil
      syncDriver = driver
      sync = SyncDatabase(driver: driver)
      defaultConnection = Connection(native: nativeConnection, syncDriver: driver)
    } else {
      let pathString = OwnedCString(path)
      var config = turso_database_config_t()
      config.async_io = 0
      config.path = UnsafePointer(pathString.pointer)

      var databasePointer: OpaquePointer?
      try NativeStatus.call {
        turso_database_new(&config, &databasePointer, $0)
      }
      guard let databasePointer else {
        throw TursoError.internalError("Turso did not return a database handle.")
      }
      let database = NativeDatabase(databasePointer)
      try NativeStatus.call {
        turso_database_open(database.pointer, $0)
      }

      var connectionPointer: OpaquePointer?
      try NativeStatus.call {
        turso_database_connect(database.pointer, &connectionPointer, $0)
      }
      guard let connectionPointer else {
        throw TursoError.internalError("Turso did not return a connection handle.")
      }
      localDatabase = database
      syncDriver = nil
      sync = SyncDatabase(driver: nil)
      defaultConnection = Connection(
        native: NativeConnection(connectionPointer, owner: database),
        syncDriver: nil
      )
    }
  }

  public func connect() async throws -> Connection {
    if let syncDriver {
      return Connection(
        native: try await syncDriver.connect(),
        syncDriver: syncDriver
      )
    }
    guard let localDatabase else {
      throw TursoError.internalError("Database handle is unavailable.")
    }
    var connectionPointer: OpaquePointer?
    try NativeStatus.call {
      turso_database_connect(localDatabase.pointer, &connectionPointer, $0)
    }
    guard let connectionPointer else {
      throw TursoError.internalError("Turso did not return a connection handle.")
    }
    return Connection(
      native: NativeConnection(connectionPointer, owner: localDatabase),
      syncDriver: nil
    )
  }

  @discardableResult
  public func execute(_ sql: String, _ arguments: [Value] = []) async throws -> Int64 {
    try await defaultConnection.execute(sql, arguments)
  }

  public func query(_ sql: String, _ arguments: [Value] = []) async throws -> [Row] {
    try await defaultConnection.query(sql, arguments)
  }
}
