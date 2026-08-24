# Turso Swift

An async Swift interface to the embedded Turso database and Turso Cloud sync.
The package wraps Turso's Rust `sdk-kit` and `sync-sdk-kit` through their C ABI;
applications import only the `Turso` Swift module.

## Requirements

- Swift 6.0 or newer
- macOS 13 or newer
- iOS 16 or newer

The checked-in `CTurso.xcframework` contains universal macOS, iOS device, and
iOS Simulator slices, so consumers do not need Rust installed.

## Installation

Add this repository as a Swift Package dependency, then add the `Turso`
library product to your application target:

```swift
.package(url: "https://github.com/migratrom/turso.swift.git", from: "0.1.0")
```

## Local database

```swift
import Turso

let database = try await Database(path: "local.db")

try await database.execute(
    "CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, name TEXT NOT NULL)"
)

try await database.execute(
    "INSERT INTO users(name) VALUES (?)",
    ["Alloys"]
)

let rows = try await database.query(
    "SELECT id, name FROM users WHERE name = ?",
    ["Alloys"]
)

print(rows[0][column: "name"]?.string ?? "")
```

`Value` supports null, integer, real, text, and blob values. Integer, floating
point, and string literals convert directly when Swift can infer `[Value]`.

## Cloud sync

```swift
let database = try await Database(
    path: "local.db",
    sync: .init(
        url: "libsql://example.turso.io",
        authToken: token
    )
)

try await database.execute(
    "INSERT INTO users(name) VALUES (?)",
    ["Alloys"]
)

try await database.sync.push()
let changed = try await database.sync.pull()
```

The sync driver performs the HTTP and atomic file requests emitted by
`sync-sdk-kit` using `URLSession` and Swift concurrency. Access is serialized
across native operations because the underlying connection and operation
handles require exclusive use.

`database.sync` is always available. On a database created without a sync
configuration, its operations throw `TursoError.syncNotConfigured`.

## Lower-level access

Use `database.connect()` to obtain an independent `Connection`, or prepare a
reusable `Statement`:

```swift
let connection = try await database.connect()
let statement = try await connection.prepare("SELECT name FROM users WHERE id = ?")
try await statement.bind([1])
let row = try await statement.step()
try await statement.finalize()
```

Rows are copied out of the native statement buffer, so they remain valid after
the statement advances or is finalized.

## Rebuilding the native artifact

The native framework is built from Turso commit
`c5816b5f5f5d2568e551a746f92f893003e55234` (`0.8.0-pre.7`). To reproduce it,
install Rust and Xcode, then run:

```sh
./Scripts/build-xcframework.sh
```

The build script downloads that pinned source revision and replaces
`Vendor/CTurso.xcframework` only after all slices have compiled.

## License

MIT. The vendored Turso SDK-kit code is also distributed under the MIT license.
