import Foundation
import XCTest

@testable import Turso

final class TursoTests: XCTestCase {
  func testExecuteBindAndQuery() async throws {
    let database = try await Database(path: ":memory:")
    try await database.execute(
      "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, payload BLOB)"
    )

    let changes = try await database.execute(
      "INSERT INTO users(name, score, payload) VALUES (?, ?, ?)",
      ["Alloys", 9.5, .blob(Data([0xCA, 0xFE]))]
    )
    XCTAssertEqual(changes, 1)

    let rows = try await database.query(
      "SELECT id, name, score, payload FROM users WHERE name = ?",
      ["Alloys"]
    )
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0][column: "id"], .integer(1))
    XCTAssertEqual(rows[0][column: "name"], .text("Alloys"))
    XCTAssertEqual(rows[0][column: "score"], .real(9.5))
    XCTAssertEqual(rows[0][column: "payload"], .blob(Data([0xCA, 0xFE])))
  }

  func testNullAndEmptyValuesAreOwned() async throws {
    let database = try await Database(path: ":memory:")
    let rows = try await database.query(
      "SELECT NULL AS missing, '' AS empty_text, x'' AS empty_blob"
    )

    XCTAssertEqual(rows[0][column: "missing"], .null)
    XCTAssertEqual(rows[0][column: "empty_text"], .text(""))
    XCTAssertEqual(rows[0][column: "empty_blob"], .blob(Data()))
  }

  func testParameterCountIsValidated() async throws {
    let database = try await Database(path: ":memory:")
    do {
      try await database.execute("SELECT ?, ?", [1])
      XCTFail("Expected invalidArgument")
    } catch let error as TursoError {
      guard case .invalidArgument = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testSyncFacadeReportsMissingConfiguration() async throws {
    let database = try await Database(path: ":memory:")
    XCTAssertFalse(database.sync.isConfigured)
    do {
      try await database.sync.push()
      XCTFail("Expected syncNotConfigured")
    } catch let error as TursoError {
      XCTAssertEqual(error, .syncNotConfigured)
    }
  }

  func testSyncDatabaseCanOpenOfflineWhenBootstrapIsDisabled() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try await Database(
      path: directory.appendingPathComponent("local.db").path,
      sync: .init(
        url: "http://127.0.0.1:1",
        authToken: "",
        bootstrapIfEmpty: false
      )
    )
    XCTAssertTrue(database.sync.isConfigured)
    try await database.execute("CREATE TABLE local_only(value TEXT)")
    try await database.execute("INSERT INTO local_only VALUES (?)", ["offline"])
    let value = try await database.query("SELECT value FROM local_only").first?["value"]
    XCTAssertEqual(value, .text("offline"))
  }
}
