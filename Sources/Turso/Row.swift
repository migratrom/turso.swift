/// An owned snapshot of a result row.
public struct Row: Sendable, Hashable, RandomAccessCollection {
  public typealias Index = Int
  public typealias Element = Value

  public let columnNames: [String]
  private let storage: [Value]
  private let indices: [String: Int]

  public init(columnNames: [String], values: [Value]) {
    self.columnNames = columnNames
    self.storage = values
    self.indices = Dictionary(
      columnNames.enumerated().map { ($0.element, $0.offset) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  public var startIndex: Int { storage.startIndex }
  public var endIndex: Int { storage.endIndex }

  public subscript(position: Int) -> Value {
    storage[position]
  }

  public subscript(column column: String) -> Value? {
    indices[column].map { storage[$0] }
  }

  public subscript(_ column: String) -> Value? {
    self[column: column]
  }
}
