import Foundation

/// Configuration for a local database that synchronizes with Turso Cloud.
public struct SyncConfiguration: Sendable, Hashable {
  public var url: String
  public var authToken: String
  public var clientName: String
  public var bootstrapIfEmpty: Bool
  public var longPollTimeoutMilliseconds: Int32

  public init(
    url: String,
    authToken: String,
    clientName: String = "turso-swift",
    bootstrapIfEmpty: Bool = true,
    longPollTimeoutMilliseconds: Int32 = 0
  ) {
    self.url = url
    self.authToken = authToken
    self.clientName = clientName
    self.bootstrapIfEmpty = bootstrapIfEmpty
    self.longPollTimeoutMilliseconds = longPollTimeoutMilliseconds
  }
}

public struct SyncStats: Sendable, Hashable {
  public let pendingOperations: Int64
  public let mainWALSize: Int64
  public let revertWALSize: Int64
  public let lastPullUnixTime: Int64
  public let lastPushUnixTime: Int64
  public let networkSentBytes: Int64
  public let networkReceivedBytes: Int64
  public let revision: String
}

/// The synchronization interface associated with a `Database`.
public struct SyncDatabase: Sendable {
  internal let driver: SyncIODriver?

  internal init(driver: SyncIODriver?) {
    self.driver = driver
  }

  public var isConfigured: Bool { driver != nil }

  public func push() async throws {
    guard let driver else { throw TursoError.syncNotConfigured }
    try await driver.push()
  }

  /// Pulls and applies remote changes. Returns whether changes were applied.
  @discardableResult
  public func pull() async throws -> Bool {
    guard let driver else { throw TursoError.syncNotConfigured }
    return try await driver.pull()
  }

  public func checkpoint() async throws {
    guard let driver else { throw TursoError.syncNotConfigured }
    try await driver.checkpoint()
  }

  public func stats() async throws -> SyncStats {
    guard let driver else { throw TursoError.syncNotConfigured }
    return try await driver.stats()
  }
}
