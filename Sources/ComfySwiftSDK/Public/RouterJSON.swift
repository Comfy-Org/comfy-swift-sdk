import Foundation

/// A `Sendable`, value-typed view of an arbitrary JSON document.
///
/// The Comfy Router surface carries two payloads whose shape is owned by the
/// partner provider rather than by Comfy — a validation error's `ctx` (the
/// violated bound) and its `input` (the offending value echoed back). Neither
/// can be narrowed to a fixed field list without losing the branch a caller
/// reads, and neither may be surfaced as `Any`: `RouterError` is `Sendable`, and
/// `Any` is not. `RouterJSON` is the box that keeps both properties.
///
/// Construct one from `JSONSerialization` output with ``init(any:)``. Navigate
/// it with the two subscripts — both return ``RouterJSON/null`` on a miss, so a
/// deep read never traps — and unwrap leaves with the typed accessors, each of
/// which returns `nil` when the value is of another kind.
///
/// ```swift
/// let json = RouterJSON(any: try JSONSerialization.jsonObject(with: data))
/// let limit = json["ctx"]["limit_value"].intValue   // nil if absent or non-numeric
/// ```
///
/// ## Integers
///
/// A JSON number arrives as either ``int(_:)`` or ``number(_:)`` depending on how it was
/// *written*, not on its value: `2` is an ``int`` and `2.0` is a ``number``. The split
/// exists because `Double` cannot hold every 64-bit integer — `9007199254740993` rounds to
/// `…992` — and this type's whole job is to carry a provider's `ctx` and `input` verbatim.
/// In this domain that lost bit is typically a generation seed, and a silently rounded seed
/// produces unreproducible output from a call that looked like it succeeded.
///
/// The two cases are deliberately **not** equal to one another: `.int(1) != .number(1.0)`.
/// They are distinct wire shapes, and collapsing them would make round-tripping a document
/// through this type unobservable in a test. Read a number through ``intValue`` or
/// ``doubleValue`` — both answer for either case — rather than by matching a case, unless
/// the wire shape is what you actually mean to assert.
public enum RouterJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([RouterJSON])
    case object([String: RouterJSON])

    /// Wrap the output of `JSONSerialization.jsonObject(with:)`.
    ///
    /// Anything the initializer does not recognise — which, for genuine
    /// `JSONSerialization` output, is only `NSNull` — becomes ``null`` rather
    /// than a failure: this type exists to carry a diagnostic payload onto an
    /// error that is already being constructed, so it never throws.
    public init(any value: Any) {
        switch value {
        case let nested as RouterJSON:
            self = nested
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // `as? Bool` is not usable here: `NSNumber(value: 1) as? Bool`
            // succeeds via bridging, so every integral 0/1 would decode as a
            // boolean. The Core Foundation type id is the only reliable
            // separator between the `__NSCFBoolean` singletons and a numeric
            // `NSNumber`, and it has to be asked first for the same reason.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number as CFNumber) {
                // The number's *declared* type, never a range check on its value:
                // `2.0` was written as a JSON float and stays one. A value
                // heuristic would quietly turn it into an `.int`.
                self = .number(number.doubleValue)
            } else if let exact = Int(exactly: number.int64Value),
                      NSNumber(value: exact).isEqual(to: number) {
                self = .int(exact)
            } else {
                // Integral, but not an `Int`. `JSONSerialization` hands an integer
                // literal above `Int64.max` back as an *unsigned* `NSNumber` whose
                // `int64Value` silently wraps — `9223372036854775808` reads as
                // `Int.min` — which is what the round-trip comparison above is
                // guarding, not a theoretical case. Carried as a `Double`, which is
                // lossy but honest, rather than as a wrong `Int`.
                self = .number(number.doubleValue)
            }
        case let bool as Bool:
            // Non-`NSNumber` boxing (a Swift `Bool` in an `[String: Any]` that
            // never went through `JSONSerialization`).
            self = .bool(bool)
        case let array as [Any]:
            self = .array(array.map(RouterJSON.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(RouterJSON.init(any:)))
        default:
            self = .null
        }
    }

    /// The value at `key`, or ``null`` when this is not an object or the key is absent.
    public subscript(key: String) -> RouterJSON {
        guard case .object(let object) = self, let value = object[key] else { return .null }
        return value
    }

    /// The element at `index`, or ``null`` when this is not an array or the index is out of range.
    public subscript(index: Int) -> RouterJSON {
        guard case .array(let array) = self, array.indices.contains(index) else { return .null }
        return array[index]
    }

    /// The string payload, or `nil` if this is not a ``string``.
    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// The numeric payload as a `Double`, or `nil` if this is neither a ``number`` nor an
    /// ``int``. An ``int`` beyond 2^53 converts lossily — that is `Double`'s limit, and the
    /// reason ``intValue`` exists alongside this.
    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    /// The numeric payload as an `Int`.
    ///
    /// An ``int`` answers exactly — that is the case's entire purpose. A ``number`` answers
    /// when it represents an exact integer within `Int`'s range, so `2.0` still reads as
    /// `2`; a fractional or out-of-range value is a miss, not a silent truncation. Anything
    /// else is `nil`.
    ///
    /// On the ``number`` path the upper bound is deliberately exclusive. `Double(Int.max)`
    /// rounds *up* to 2^63, which is one past `Int.max`, so an inclusive `<=` would admit a
    /// JSON `9223372036854775808` and then trap in `Int(_:)` — a crash reachable from a
    /// server-controlled response body, inside an error path that must never fail.
    /// `Double(Int.min)` is exactly -2^63 and is representable, so the lower bound stays
    /// inclusive.
    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .number(let value):
            guard value.rounded() == value,
                  value >= Double(Int.min), value < Double(Int.max) else { return nil }
            return Int(value)
        default:
            return nil
        }
    }

    /// The boolean payload, or `nil` if this is not a ``bool``.
    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// The elements, or `nil` if this is not an ``array``.
    public var arrayValue: [RouterJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    /// The members, or `nil` if this is not an ``object``.
    public var objectValue: [String: RouterJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}
