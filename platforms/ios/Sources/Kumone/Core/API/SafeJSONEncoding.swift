import Foundation

/// `NSJSONSerialization` raises Objective-C `NSException`s — not Swift errors —
/// for an invalid top-level object (anything other than an array/dictionary)
/// and for unsupported nested values. `try?` cannot catch those: the exception
/// escapes to `objc_exception_throw` and the process aborts with SIGABRT.
///
/// This was the root cause of the "every operation crashes" report: the
/// `__set_timeout__` host callback passes an integer timer id as the top-level
/// value, and `LXUserAPIPreload.js` expects exactly `JSON.parse("123")` on the
/// JS side. Emitting a JSON fragment keeps the wire format unchanged while
/// removing the exception.
///
/// Every JSON write in the LX User API bridge must go through this helper,
/// which normalises the value first and only calls Foundation with an input
/// that is guaranteed to be valid.
enum SafeJSON {
    /// Returns a UTF-8 JSON string, or nil when `value` is nil or cannot be
    /// represented. Scalar top-level values are emitted as JSON fragments.
    static func encodedString(_ value: Any?, allowFragments: Bool = true) -> String? {
        guard let value,
              let data = encodedData(value, allowFragments: allowFragments),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    static func encodedData(_ value: Any, allowFragments: Bool = true) -> Data? {
        let normalized = jsonSafe(value)
        let options: JSONSerialization.WritingOptions
        if isContainer(normalized) {
            // A nested URL/Date/custom Swift value would still make Foundation
            // throw an NSException, so re-check after normalisation.
            guard JSONSerialization.isValidJSONObject(normalized) else { return nil }
            options = []
        } else if isScalar(normalized) {
            guard allowFragments else { return nil }
            options = [.fragmentsAllowed]
        } else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: normalized, options: options)
    }

    private static func isContainer(_ value: Any) -> Bool {
        value is [Any] || value is [String: Any] || value is NSArray || value is NSDictionary
    }

    private static func isScalar(_ value: Any) -> Bool {
        value is String || value is NSNumber || value is NSNull
    }

    /// Recursively converts anything Foundation cannot serialize into a JSON
    /// safe representation. Also unwraps nested Optionals, which otherwise
    /// bridge to `_SwiftValue` and trigger "Invalid type in JSON write".
    ///
    /// The result is always one of: `[String: Any]`, `[Any]`, `String`,
    /// `NSNumber`, or `NSNull`. Keeping that invariant is what makes
    /// `encodedData` safe to call without an exception handler.
    private static func jsonSafe(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 16 else { return String(describing: value) }

        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return NSNull() }
            return jsonSafe(child.value, depth: depth + 1)
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = jsonSafe(pair.value, depth: depth + 1)
            }
        }
        if let dictionary = value as? NSDictionary {
            var result: [String: Any] = [:]
            for rawKey in dictionary.allKeys {
                let nested = dictionary.object(forKey: rawKey) ?? NSNull()
                result[String(describing: rawKey)] = jsonSafe(nested, depth: depth + 1)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { jsonSafe($0, depth: depth + 1) }
        }

        switch value {
        case is NSNull:
            return NSNull()
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let bool as Bool:
            return NSNumber(value: bool)
        case let int as Int:
            return NSNumber(value: int)
        case let int64 as Int64:
            return NSNumber(value: int64)
        case let uint as UInt:
            return NSNumber(value: uint)
        case let double as Double:
            return NSNumber(value: double)
        case let float as Float:
            return NSNumber(value: float)
        case let decimal as Decimal:
            return NSDecimalNumber(decimal: decimal)
        case let url as URL:
            return url.absoluteString
        case let date as Date:
            return NSNumber(value: date.timeIntervalSince1970)
        case let data as Data:
            return data.base64EncodedString()
        default:
            return String(describing: value)
        }
    }
}
