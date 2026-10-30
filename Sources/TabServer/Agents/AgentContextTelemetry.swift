import CoreFoundation
import Foundation

/// Reject malformed telemetry rather than coercing strings, booleans or fractional counts.
internal func agentTokenCount(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let count = Int(number.stringValue), count >= 0 else { return nil }
    return count
}

internal func agentContextWindow(_ value: Any?) -> Int? {
    guard let count = agentTokenCount(value), count > 0 else { return nil }
    return count
}
