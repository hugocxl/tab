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

/// Claude's compact_boundary contract rounds positive post_tokens (the pinned
/// adapter does not apply ordinary integer-only usage telemetry parsing here).
internal func agentCompactionAfterTokens(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let count = number.doubleValue
    guard count.isFinite, count > 0, count.rounded() <= 9_007_199_254_740_991 else { return nil }
    return Int(count.rounded())
}
