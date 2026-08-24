import CTurso
import Foundation

internal final class SyncIODriver: @unchecked Sendable {
  private let native: NativeSyncDatabase
  private let baseURL: URL
  private let authToken: String
  private let gate = AsyncMutex()

  init(path: String, configuration: SyncConfiguration) throws {
    guard !path.isEmpty else {
      throw TursoError.invalidArgument("Database path must not be empty.")
    }
    guard let normalizedURL = Self.normalizedURL(configuration.url) else {
      throw TursoError.invalidArgument("Invalid Turso sync URL: \(configuration.url)")
    }
    baseURL = normalizedURL
    authToken = configuration.authToken

    let pathString = OwnedCString(path)
    let remoteString = OwnedCString(normalizedURL.absoluteString)
    let clientString = OwnedCString(configuration.clientName)

    var databaseConfig = turso_database_config_t()
    databaseConfig.async_io = 1
    databaseConfig.path = UnsafePointer(pathString.pointer)

    var syncConfig = turso_sync_database_config_t()
    syncConfig.path = UnsafePointer(pathString.pointer)
    syncConfig.remote_url = UnsafePointer(remoteString.pointer)
    syncConfig.client_name = UnsafePointer(clientString.pointer)
    syncConfig.long_poll_timeout_ms = configuration.longPollTimeoutMilliseconds
    syncConfig.bootstrap_if_empty = configuration.bootstrapIfEmpty

    var pointer: OpaquePointer?
    try NativeStatus.call {
      turso_sync_database_new(
        &databaseConfig,
        &syncConfig,
        &pointer,
        $0
      )
    }
    guard let pointer else {
      throw TursoError.internalError("Turso did not return a sync database handle.")
    }
    native = NativeSyncDatabase(pointer)
  }

  func create() async throws {
    try await gate.withLock { [self] in
      let operation = try start { output, error in
        turso_sync_database_create(native.pointer, output, error)
      }
      try await driveUnlocked(operation)
    }
  }

  func connect() async throws -> NativeConnection {
    try await gate.withLock { [self] in
      let operation = try start { output, error in
        turso_sync_database_connect(native.pointer, output, error)
      }
      try await driveUnlocked(operation)
      var pointer: OpaquePointer?
      try NativeStatus.check(
        turso_sync_operation_result_extract_connection(operation.pointer, &pointer)
      )
      guard let pointer else {
        throw TursoError.internalError("Turso did not return a connection handle.")
      }
      return NativeConnection(pointer, owner: self)
    }
  }

  func push() async throws {
    try await gate.withLock { [self] in
      let operation = try start { output, error in
        turso_sync_database_push_changes(native.pointer, output, error)
      }
      try await driveUnlocked(operation)
    }
  }

  func pull() async throws -> Bool {
    try await gate.withLock { [self] in
      let waitOperation = try start { output, error in
        turso_sync_database_wait_changes(native.pointer, output, error)
      }
      try await driveUnlocked(waitOperation)

      var changes: OpaquePointer?
      try NativeStatus.check(
        turso_sync_operation_result_extract_changes(waitOperation.pointer, &changes)
      )
      guard let changes else { return false }

      let applyOperation = try start { output, error in
        turso_sync_database_apply_changes(native.pointer, changes, output, error)
      }
      try await driveUnlocked(applyOperation)
      return true
    }
  }

  func checkpoint() async throws {
    try await gate.withLock { [self] in
      let operation = try start { output, error in
        turso_sync_database_checkpoint(native.pointer, output, error)
      }
      try await driveUnlocked(operation)
    }
  }

  func stats() async throws -> SyncStats {
    try await gate.withLock { [self] in
      let operation = try start { output, error in
        turso_sync_database_stats(native.pointer, output, error)
      }
      try await driveUnlocked(operation)
      var stats = turso_sync_stats_t()
      try NativeStatus.check(
        turso_sync_operation_result_extract_stats(operation.pointer, &stats)
      )
      return SyncStats(
        pendingOperations: stats.cdc_operations,
        mainWALSize: stats.main_wal_size,
        revertWALSize: stats.revert_wal_size,
        lastPullUnixTime: stats.last_pull_unix_time,
        lastPushUnixTime: stats.last_push_unix_time,
        networkSentBytes: stats.network_sent_bytes,
        networkReceivedBytes: stats.network_received_bytes,
        revision: copiedString(stats.revision)
      )
    }
  }

  /// Services at most one sync-engine I/O item while a SQL statement advances.
  func processOneIO() async throws {
    try await gate.withLock { [self] in
      try Task.checkCancellation()
      if let item = try takeIOItem() {
        try await handle(item)
      }
      try NativeStatus.call {
        turso_sync_database_io_step_callbacks(native.pointer, $0)
      }
    }
  }

  private typealias OperationStarter = (
    UnsafeMutablePointer<OpaquePointer?>,
    UnsafeMutablePointer<UnsafePointer<CChar>?>
  ) -> turso_status_code_t

  private func start(_ starter: OperationStarter) throws -> NativeOperation {
    var pointer: OpaquePointer?
    try NativeStatus.call { starter(&pointer, $0) }
    guard let pointer else {
      throw TursoError.internalError("Turso did not return an operation handle.")
    }
    return NativeOperation(pointer)
  }

  private func driveUnlocked(_ operation: NativeOperation) async throws {
    while true {
      try Task.checkCancellation()
      let status = try NativeStatus.call(
        allowing: [NativeStatus.ok, NativeStatus.done, NativeStatus.io]
      ) {
        turso_sync_operation_resume(operation.pointer, $0)
      }
      switch status {
      case NativeStatus.done:
        return
      case NativeStatus.io:
        try await processIOQueueUnlocked()
      case NativeStatus.ok:
        await Task.yield()
      default:
        throw TursoError.internalError("Unexpected sync operation status \(status).")
      }
    }
  }

  private func processIOQueueUnlocked() async throws {
    while let item = try takeIOItem() {
      try Task.checkCancellation()
      try await handle(item)
    }
    try NativeStatus.call {
      turso_sync_database_io_step_callbacks(native.pointer, $0)
    }
  }

  private func takeIOItem() throws -> NativeIOItem? {
    var pointer: OpaquePointer?
    try NativeStatus.call {
      turso_sync_database_io_take_item(native.pointer, &pointer, $0)
    }
    return pointer.map(NativeIOItem.init)
  }

  private func handle(_ item: NativeIOItem) async throws {
    do {
      switch turso_sync_database_io_request_kind(item.pointer).rawValue {
      case TURSO_SYNC_IO_HTTP.rawValue:
        try await handleHTTP(item)
      case TURSO_SYNC_IO_FULL_READ.rawValue:
        try handleFullRead(item)
      case TURSO_SYNC_IO_FULL_WRITE.rawValue:
        try handleFullWrite(item)
      default:
        break
      }
      try NativeStatus.check(turso_sync_database_io_done(item.pointer))
    } catch {
      let message = String(describing: error)
      try? withSlice(message) { slice in
        try NativeStatus.check(turso_sync_database_io_poison(item.pointer, &slice))
      }
      try? NativeStatus.check(turso_sync_database_io_done(item.pointer))
      if Task.isCancelled || error is CancellationError {
        throw TursoError.cancelled
      }
      // The poisoned completion is resumed by the engine after callbacks
      // are stepped, preserving the native error category and context.
    }
  }

  private func handleHTTP(_ item: NativeIOItem) async throws {
    var nativeRequest = turso_sync_io_http_request_t()
    try NativeStatus.check(
      turso_sync_database_io_request_http(item.pointer, &nativeRequest)
    )

    let method = copiedString(nativeRequest.method)
    let path = copiedString(nativeRequest.path)
    let requestedBase = copiedString(nativeRequest.url)
    let requestURL: URL?
    if let absolute = URL(string: path), absolute.scheme != nil {
      requestURL = absolute
    } else {
      let base = requestedBase.isEmpty ? baseURL : (Self.normalizedURL(requestedBase) ?? baseURL)
      requestURL =
        URL(string: path.hasPrefix("/") ? String(path.dropFirst()) : path, relativeTo: base)?
        .absoluteURL
    }
    guard let requestURL else {
      throw TursoError.network("Sync engine produced an invalid request URL.")
    }

    var request = URLRequest(url: requestURL)
    request.httpMethod = method
    request.httpBody = copiedData(nativeRequest.body)
    for index in 0..<Int(nativeRequest.headers) {
      var header = turso_sync_io_http_header_t()
      try NativeStatus.check(
        turso_sync_database_io_request_http_header(item.pointer, index, &header)
      )
      request.addValue(copiedString(header.value), forHTTPHeaderField: copiedString(header.key))
    }
    if !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
    if request.value(forHTTPHeaderField: "User-Agent") == nil {
      request.setValue("turso-swift", forHTTPHeaderField: "User-Agent")
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TursoError.network("Sync request returned a non-HTTP response.")
    }
    try NativeStatus.check(
      turso_sync_database_io_status(item.pointer, Int32(httpResponse.statusCode))
    )
    if !data.isEmpty {
      try withSlice(data) { slice in
        try NativeStatus.check(turso_sync_database_io_push_buffer(item.pointer, &slice))
      }
    }
  }

  private func handleFullRead(_ item: NativeIOItem) throws {
    var request = turso_sync_io_full_read_request_t()
    try NativeStatus.check(
      turso_sync_database_io_request_full_read(item.pointer, &request)
    )
    let url = URL(fileURLWithPath: copiedString(request.path))
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let data = try Data(contentsOf: url)
    if !data.isEmpty {
      try withSlice(data) { slice in
        try NativeStatus.check(turso_sync_database_io_push_buffer(item.pointer, &slice))
      }
    }
  }

  private func handleFullWrite(_ item: NativeIOItem) throws {
    var request = turso_sync_io_full_write_request_t()
    try NativeStatus.check(
      turso_sync_database_io_request_full_write(item.pointer, &request)
    )
    let url = URL(fileURLWithPath: copiedString(request.path))
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try copiedData(request.content).write(to: url, options: .atomic)
  }

  private static func normalizedURL(_ value: String) -> URL? {
    var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("libsql://") {
      normalized.replaceSubrange(
        normalized.startIndex..<normalized.index(normalized.startIndex, offsetBy: 9),
        with: "https://")
    } else if normalized.hasPrefix("turso://") {
      normalized.replaceSubrange(
        normalized.startIndex..<normalized.index(normalized.startIndex, offsetBy: 8),
        with: "https://")
    }
    guard var components = URLComponents(string: normalized),
      components.scheme == "https" || components.scheme == "http",
      components.host != nil
    else { return nil }
    if !components.path.hasSuffix("/") { components.path += "/" }
    return components.url
  }
}
