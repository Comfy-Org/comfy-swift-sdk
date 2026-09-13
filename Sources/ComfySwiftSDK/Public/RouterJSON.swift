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
/// through this type unobservable in a test.
///
/// Read a number through ``intValue`` rather than by matching a case: it answers for both
/// cases, and it is the accessor that preserves exactness where exactness is available. That
/// is not everywhere — on the ``number`` path an answer is exact only below 2^53, because a
/// float-written value was already rounded by the parser before this type saw it. Above that
/// magnitude exactness is the ``int`` case's property rather than the accessor's: it carries
/// an integer-written value verbatim and never consults a `Double`.
/// Match a case only when the wire shape is what you actually mean to assert — and note
/// that `if case .number` on its own no longer sees an integer-written number, nor does an
/// `Equatable` comparison against `.number(512)` match a parsed `512`.
///
/// The exactness guarantee stops at `Int`'s width, and that limit is real rather than
/// theoretical: an integral JSON number above `Int64.max` — which `JSONSerialization` hands
/// back as an unsigned `NSNumber` — cannot be held by ``int`` and is carried as a
/// ``number``. It is then subject to `Double`'s precision, so `9223372036854775808` and
/// `9223372036854775809` land on the same value. Values outside `Int`'s range — in either
/// direction — are **not** carried verbatim, and ``intValue`` answers `nil` for them rather
/// than guessing; a caller that must distinguish them has to read the raw body itself.
///
/// ``doubleValue`` answers for both cases too, but it is **not** interchangeable with
/// ``intValue``: an ``int`` past 2^53 rounds on the way out, so `.int(9007199254740993)`
/// reads back as `…992`. That is `Double`'s limit rather than this type's, and it is the
/// very loss the ``int`` case exists to prevent — so reach for ``doubleValue`` only when a
/// floating-point magnitude is what you want, never for a seed, an id, or anything else
/// that has to survive exactly.
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
            } else if !RouterJSON.isUnsignedBeyondIntMax(number),
                      let exact = Int(exactly: number.int64Value),
                      number.stringValue == String(exact) {
                self = .int(exact)
            } else {
                // Integral, but not an `Int`. `JSONSerialization` hands an integer
                // literal above `Int64.max` back as an *unsigned* `NSNumber` whose
                // `int64Value` silently wraps — `9223372036854775808` reads as
                // `Int.min` — which is what the guards above reject, not a
                // theoretical case. Carried as a `Double`, which is lossy but
                // honest, rather than as a wrong `Int`.
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

    /// Whether `number` stores an unsigned value larger than `Int64.max` — the one shape
    /// whose `int64Value` silently wraps into a negative number.
    ///
    /// `JSONSerialization` hands an integer literal above `Int64.max` back as an unsigned
    /// `NSNumber` (Objective-C type encoding `"Q"`), whose `int64Value` reads
    /// `9223372036854775808` as `Int.min`. This test is on the declared representation and
    /// on the unsigned value, both of which are specified.
    ///
    /// An `NSNumber(value:).isEqual(to:)` round-trip would also catch this, but only by
    /// relying on how `NSNumber` compares *across* signedness — which `CFNumber`, having no
    /// unsigned storage, does not specify. The decision rests on no such behaviour: this
    /// check is on the encoding, and the call site's `stringValue` comparison is on the
    /// value.
    ///
    /// That second check is what makes this one safe to be wrong about. The `"Q"` encoding
    /// is not guaranteed everywhere — swift-corelibs-foundation derives it from the
    /// `CFNumber` type, where a value this wide can report something else — and on its own
    /// this test would then let `int64Value` wrap through `Int(exactly:)` and produce
    /// `.int(Int.min)`: sign-flipped and presented as exact, which is worse than the lossy
    /// ``number`` fallback. `stringValue` catches that, and catches non-`JSONSerialization`
    /// input through the public ``init(any:)`` too — an `NSDecimalNumber(2.5)`, whose
    /// `int64Value` truncates to `2`, fails the comparison and stays a ``number``.
    private static func isUnsignedBeyondIntMax(_ number: NSNumber) -> Bool {
        String(cString: number.objCType) == "Q" && number.uint64Value > UInt64(Int64.max)
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
    /// On the ``number`` path **both** bounds are exclusive, and for the same reason.
    ///
    /// `Double(Int.max)` rounds *up* to 2^63, one past `Int.max`, so an inclusive `<=` would
    /// admit a JSON `9223372036854775808` and then trap in `Int(_:)` — a crash reachable
    /// from a server-controlled response body, inside an error path that must never fail.
    ///
    /// `Double(Int.min)` is exactly -2^63 and so cannot trap, but an inclusive `>=` there is
    /// wrong for a subtler reason: more than one integer rounds onto it. `JSONSerialization`
    /// turns `-9223372036854775809` into exactly -2^63, so an inclusive bound answers
    /// `Int.min` — a value that is off by one and indistinguishable from an exact read. That
    /// is the silent corruption the ``int`` case exists to prevent, arriving through the
    /// accessor instead. Excluding it costs only a *float-written* `-9.223372036854775808e18`,
    /// while an integer-written `-9223372036854775808` still answers exactly, because it
    /// arrives as an ``int`` and never reaches this path.
    ///
    /// Those bounds remove the two values that would answer *wrongly at the edges*; they do
    /// not make the ``number`` path exact in general, and nothing here can. Above 2^53 a
    /// `Double` has already lost the distinction between adjacent integers before this type
    /// saw it, so a float-written `9007199254740993.0` still reads back as `…992` and the
    /// `rounded() == value` test cannot tell a genuinely integral value from one rounded
    /// onto an integer by the parser. **On the ``number`` path, treat an answer as exact
    /// only below 2^53.** Above that, exactness is what the ``int`` case is for: it carries
    /// an integer-written value verbatim and never consults a `Double` at all.
    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .number(let value):
            guard value.rounded() == value,
                  value > Double(Int.min), value < Double(Int.max) else { return nil }
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
