import Foundation

/// A value that can be bound to, or returned from, a Turso statement.
public enum Value: Sendable, Hashable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)
}

extension Value: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) { self = .null }
}

extension Value: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int64) { self = .integer(value) }
}

extension Value: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) { self = .real(value) }
}

extension Value: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .text(value) }
}

extension Value {
  public var int64: Int64? {
    guard case .integer(let value) = self else { return nil }
    return value
  }

  public var double: Double? {
    switch self {
    case .real(let value): value
    case .integer(let value): Double(value)
    default: nil
    }
  }

  public var string: String? {
    guard case .text(let value) = self else { return nil }
    return value
  }

  public var data: Data? {
    guard case .blob(let value) = self else { return nil }
    return value
  }

  public var isNull: Bool {
    if case .null = self { true } else { false }
  }
}
