import XCTest

@testable import Turso

final class CDCTests: XCTestCase {
  func testCDCRecordsInsertUpdateAndDelete() async throws {
    let database = try await Database(path: ":memory:")
    try await database.execute(
      "CREATE TABLE users(id INTEGER PRIMARY KEY, name TEXT NOT NULL)"
    )
    try await database.execute("PRAGMA capture_data_changes_conn('full')")

    try await database.execute("INSERT INTO users VALUES (?, ?)", [1, "Alice"])
    try await database.execute("UPDATE users SET name = ? WHERE id = ?", ["Alicia", 1])
    try await database.execute("DELETE FROM users WHERE id = ?", [1])

    let changes = try await database.query(
      """
      SELECT change_id, change_type, table_name, id, before, after, updates
      FROM turso_cdc
      WHERE table_name = 'users'
      ORDER BY change_id
      """
    )

    XCTAssertEqual(changes.count, 3)
    XCTAssertEqual(changes.map { $0["change_type"] }, [1, 0, -1])
    XCTAssertEqual(changes.map { $0["table_name"] }, ["users", "users", "users"])
    XCTAssertEqual(changes.map { $0["id"] }, [1, 1, 1])

    XCTAssertTrue(changes[0]["before"]?.isNull == true)
    XCTAssertNotNil(changes[0]["after"]?.data)
    XCTAssertNotNil(changes[1]["before"]?.data)
    XCTAssertNotNil(changes[1]["after"]?.data)
    XCTAssertNotNil(changes[1]["updates"]?.data)
    XCTAssertNotNil(changes[2]["before"]?.data)
    XCTAssertTrue(changes[2]["after"]?.isNull == true)

    let changeIDs = changes.compactMap { $0["change_id"]?.int64 }
    XCTAssertEqual(changeIDs.count, changes.count)
    XCTAssertEqual(changeIDs, changeIDs.sorted())
    XCTAssertEqual(Set(changeIDs).count, changes.count)
  }

  func testCDCCanUseACustomTableAndBeDisabled() async throws {
    let database = try await Database(path: ":memory:")
    try await database.execute("CREATE TABLE events(id INTEGER PRIMARY KEY, value TEXT)")
    try await database.execute("PRAGMA capture_data_changes_conn('id,change_log')")

    try await database.execute("INSERT INTO events VALUES (?, ?)", [1, "captured"])
    try await database.execute("PRAGMA capture_data_changes_conn('off')")
    try await database.execute("INSERT INTO events VALUES (?, ?)", [2, "ignored"])

    let changes = try await database.query(
      """
      SELECT change_type, table_name, id, before, after, updates
      FROM change_log
      WHERE table_name = 'events'
      ORDER BY change_id
      """
    )

    XCTAssertEqual(changes.count, 1)
    XCTAssertEqual(changes[0]["change_type"], 1)
    XCTAssertEqual(changes[0]["table_name"], "events")
    XCTAssertEqual(changes[0]["id"], 1)
    XCTAssertTrue(changes[0]["before"]?.isNull == true)
    XCTAssertTrue(changes[0]["after"]?.isNull == true)
    XCTAssertTrue(changes[0]["updates"]?.isNull == true)
  }
}
