import CTurso
import Foundation

internal actor AsyncMutex {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  @discardableResult
  func withLock<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    await lock()
    do {
      let result = try await operation()
      unlock()
      return result
    } catch {
      unlock()
      throw error
    }
  }

  private func lock() async {
    if !isLocked {
      isLocked = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func unlock() {
    if waiters.isEmpty {
      isLocked = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

internal final class OwnedCString {
  let pointer: UnsafeMutablePointer<CChar>

  init(_ value: String) {
    pointer = value.withCString { strdup($0)! }
  }

  deinit { free(pointer) }
}

internal final class NativeDatabase: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { turso_database_deinit(pointer) }
}

internal final class NativeSyncDatabase: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { turso_sync_database_deinit(pointer) }
}

internal final class NativeConnection: @unchecked Sendable {
  let pointer: OpaquePointer
  private let owner: AnyObject?
  init(_ pointer: OpaquePointer, owner: AnyObject? = nil) {
    self.pointer = pointer
    self.owner = owner
  }
  deinit { turso_connection_deinit(pointer) }
}

internal final class NativeStatement: @unchecked Sendable {
  let pointer: OpaquePointer
  private let owner: NativeConnection
  init(_ pointer: OpaquePointer, owner: NativeConnection) {
    self.pointer = pointer
    self.owner = owner
  }
  deinit { turso_statement_deinit(pointer) }
}

internal final class NativeOperation: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { turso_sync_operation_deinit(pointer) }
}

internal final class NativeIOItem: @unchecked Sendable {
  let pointer: OpaquePointer
  init(_ pointer: OpaquePointer) { self.pointer = pointer }
  deinit { turso_sync_database_io_item_deinit(pointer) }
}

internal func copiedData(_ slice: turso_slice_ref_t) -> Data {
  guard let pointer = slice.ptr, slice.len > 0 else { return Data() }
  return Data(bytes: pointer, count: slice.len)
}

internal func copiedString(_ slice: turso_slice_ref_t) -> String {
  String(decoding: copiedData(slice), as: UTF8.self)
}

internal func withSlice<R>(
  _ data: Data,
  _ body: (inout turso_slice_ref_t) throws -> R
) rethrows -> R {
  try data.withUnsafeBytes { buffer in
    var slice = turso_slice_ref_t(ptr: buffer.baseAddress, len: buffer.count)
    return try body(&slice)
  }
}

internal func withSlice<R>(
  _ string: String,
  _ body: (inout turso_slice_ref_t) throws -> R
) rethrows -> R {
  try withSlice(Data(string.utf8), body)
}
