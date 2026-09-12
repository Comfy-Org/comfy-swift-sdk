import Foundation

/// Classification of a Comfy Router error response into a ``RouterError``.
///
/// Deliberately a pure function over `(status, headers, body, idempotencyKey)` with no
/// networking of its own: the whole classification table is then exercisable from the test
/// suite without a transport, and the transport that will call it stays free of policy.
///
/// It **never throws**. An error response is exactly the moment a malformed body is most
/// likely, and a decode failure while building an error would replace a useful diagnosis
/// with a useless one — so every unparseable or mistyped input degrades to the next-best
/// source of the same fact.
enum RouterErrorMapping {

    // MARK: Header names
    //
    // Compared case-insensitively. `URLSession` normalises response header names on some
    // platforms and not others, and a caller may hand us a dictionary it built itself.

    private static let errorTypeHeader = "x-comfy-error-type"
    private static let requestIdHeader = "x-comfy-request-id"
    private static let retryAfterHeader = "retry-after"
    private static let replayedHeader = "idempotent-replayed"

    /// The window a `Retry-After` is honoured over, in seconds. Outside it the header is
    /// dropped — this SDK reports no advice rather than advice it can show is unusable.
    ///
    /// The floor is the contract's own `minimum: 1`. A zero or a negative is not a shorter
    /// wait, it is an unusable value.
    ///
    /// The ceiling is the life of an `Idempotency-Key`, which Router holds for 24 hours, and
    /// it applies to *every* `Retry-After` Router sends. The contract declares the header on
    /// exactly two responses — the `409 concurrency_limit_exceeded` and the
    /// `504 deadline_exceeded` — and on both it means one thing: wait, then re-send the SAME
    /// key to collect the generation that is still running. It is documented absent
    /// everywhere else, an unkeyed call included, and it is not declared on `429` or `503`
    /// at all, so there is no rate-limit reading of it to preserve.
    ///
    /// That is why a longer value is dropped rather than clamped. Advice to wait past the
    /// key's own life cannot be followed: the record is gone by the time the caller wakes,
    /// so re-sending the key dispatches and bills a SECOND generation instead of collecting
    /// the first. Clamping to the ceiling does not avoid that — it lands the caller exactly
    /// on the expiry boundary — and clamping below it would stall a caller for most of a day
    /// on what is, at that magnitude, already a server bug. Reporting `nil` leaves the
    /// caller on its own schedule, re-sending the same key, which is idempotent: it collects
    /// the in-flight call and charges nothing extra, however early it asks.
    ///
    /// The ceiling is **exclusive** for that same reason. A server-sent `86400` is
    /// contract-legal, but honouring it verbatim lands the caller on the expiry boundary
    /// exactly as clamping to it would, and refusing to produce that number while forwarding
    /// it would be a distinction without a difference.
    private static let retryAfterBounds = 1 ..< 86_400

    /// The statuses whose `Retry-After` means "re-send the SAME `Idempotency-Key` to collect
    /// the generation still running", rather than plain backoff.
    ///
    /// These are the only two responses the contract declares the header on — the
    /// `409 concurrency_limit_exceeded` and the `504 deadline_exceeded` — and the only two
    /// where the advice is unusable, and unsafe to act on, without a key. Elsewhere a
    /// `Retry-After` is ordinary backoff and is carried through regardless.
    private static let collectOnRetry: Set<Int> = [409, 504]

    /// Upper bound, in Unicode scalars, on a stored `X-Comfy-Request-Id`. The contract
    /// declares a UUID, so a value this long is already a server bug or a hostile response;
    /// the cap keeps it out of logs and error strings at an unbounded size.
    private static let requestIdMaxLength = 128

    /// Build the ``RouterError`` for one failed Router response.
    ///
    /// - Parameters:
    ///   - status: The HTTP status the response arrived with.
    ///   - headers: The response headers. Names are matched case-insensitively; a dictionary
    ///     carrying the same name in two different casings resolves to the value of the
    ///     name that sorts last — arbitrary, but the same input always resolves the same
    ///     way.
    ///   - body: The raw response body. May be empty, non-JSON, or JSON of an unexpected
    ///     shape — all three degrade rather than fail.
    ///   - idempotencyKey: The `Idempotency-Key` the call was made under, recorded on the
    ///     error so a caller can re-send it where the contract says a re-send collects the
    ///     original generation. `nil` when the call carried none — every catalog read, and
    ///     an unkeyed run.
    ///
    ///     Deliberately **not** defaulted. It is the one argument here the function cannot
    ///     infer from the response, and defaulting it would let a keyed run that forgot to
    ///     pass it compile silently and then report "no key to re-send" for a generation
    ///     that is in flight and billable — sending the caller to a new key and a second
    ///     charge. A keyless caller says so by passing an explicit `nil`.
    static func routerError(
        status: Int,
        headers: [String: String],
        body: Data,
        idempotencyKey: String?
    ) -> RouterError {
        let normalizedHeaders = normalize(headers)
        let root = jsonObject(from: body)

        // A blank key is normalised to "no key" here, once, so every read below can treat
        // non-`nil` as "a key that can actually be re-sent". The contract's
        // `RouterIdempotencyKey` is `minLength: 1`, and ``RouterError/idempotencyKey``'s own
        // doc says `nil` is what distinguishes "no key" from a real one — an empty string
        // cannot say that without being mistaken for one.
        // The trimmed form is what is stored, not the caller's original: a key carrying
        // padding or a trailing CR/LF is not the key Router recorded, and handing it back as
        // "re-sendable" would put it into a re-send header verbatim.
        let key = idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey = (key?.isEmpty ?? true) ? nil : key

        let validationErrors = validationErrors(from: root)
        let errorType = errorType(
            status: status,
            headers: normalizedHeaders,
            root: root,
            idempotencyKey: resolvedKey
        )

        return RouterError(
            errorType: errorType,
            httpStatus: status,
            detail: detail(status: status, root: root, validationErrors: validationErrors),
            validationErrors: validationErrors,
            requestId: requestId(from: normalizedHeaders),
            // Withheld only where the advice *means* "re-send the SAME key to collect the
            // generation still running" — the two answers the contract declares the header
            // on. There, with no key, there is nothing to re-send and a retry layer acting
            // on the delay would repeat an UNKEYED run, dispatching and billing a second
            // generation.
            //
            // Every other status keeps it. A `429` or `503` is not about collecting anything
            // in flight, repeating a catalog read costs nothing, and dropping a legitimate
            // "wait 30s" there would leave a caller on `retryAfter ?? 0` hammering a server
            // that asked to be left alone — suppressing on the key rather than on the
            // semantics that justify suppressing.
            retryAfter: collectOnRetry.contains(status) && resolvedKey == nil
                ? nil
                : retryAfter(from: normalizedHeaders),
            idempotencyKey: resolvedKey,
            // Presence with a usable value, like the reads above, and only where it can be
            // true: `Idempotent-Replayed` claims "served from the key's record rather than
            // run again", which is a billing-relevant assertion that a blank header does not
            // make and that cannot hold without a key.
            replayed: resolvedKey != nil && hasValue(replayedHeader, in: normalizedHeaders)
        )
    }

    // MARK: - Inputs

    /// Whether `name` is present with a non-blank value.
    ///
    /// Presence alone is not a signal: a header sent with an empty or whitespace-only value
    /// carries no information, and every other string read in this file
    /// (`x-comfy-error-type`, the body's `error_type`, `x-comfy-request-id`) already trims
    /// and rejects blank. This keeps the classification reads consistent with them.
    private static func hasValue(_ name: String, in headers: [String: String]) -> Bool {
        guard let raw = headers[name]?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !raw.isEmpty
    }

    /// Lowercase every header name once, so each lookup below is a plain dictionary hit.
    ///
    /// Walked in sorted key order rather than in `Dictionary`'s undefined one: when a caller
    /// hands us the same name in two casings only one of them can survive the fold, and
    /// which one must not vary between runs of the same input — the bucket a response
    /// classifies into, and the retry behaviour that follows from it, hang off this.
    private static func normalize(_ headers: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(headers.count)
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            normalized[name.lowercased()] = value
        }
        return normalized
    }

    /// The body parsed as a JSON object, or `nil` when it is empty, not JSON, or not an
    /// object at the top level. Both Router error bodies are objects.
    private static func jsonObject(from body: Data) -> RouterJSON? {
        guard !body.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        else { return nil }
        let json = RouterJSON(any: parsed)
        guard case .object = json else { return nil }
        return json
    }

    // MARK: - Error type

    /// `X-Comfy-Error-Type` first, then the body's `error_type`, then the status.
    ///
    /// The header is the contract's primary channel — it is set on *every* error response
    /// and is the only machine-readable bucket on the `422`, whose body has no `error_type`
    /// field at all. A header present but blank is treated as absent rather than decoded as
    /// `.unknown("")`.
    private static func errorType(
        status: Int,
        headers: [String: String],
        root: RouterJSON?,
        idempotencyKey: String?
    ) -> RouterErrorType {
        if let header = headers[errorTypeHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty {
            return RouterErrorType(rawValue: header)
        }
        if let bodyValue = root?["error_type"].stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bodyValue.isEmpty {
            return RouterErrorType(rawValue: bodyValue)
        }
        return fallbackErrorType(for: status, headers: headers, idempotencyKey: idempotencyKey)
    }

    /// The bucket a status implies when neither the header nor the body named one.
    ///
    /// A status maps to the bucket the contract pairs it with on the model-run route. Where
    /// one status carries two buckets, the more common one is chosen — `403` reads as
    /// `forbidden` rather than `not_enabled`, `429` as `concurrencyLimitExceeded` rather
    /// than `rateLimited`, `504` as `providerTimeout` rather than `deadlineExceeded` — and
    /// the ambiguity is why Router sends the header in the first place. Anything
    /// unrecognised, `500` included, is `internalError`.
    ///
    /// `409` is the one status not settled by frequency, because its two buckets are acted
    /// on in *opposite* ways: `concurrency_limit_exceeded` means the original call for this
    /// `Idempotency-Key` is still running and the answer is to re-send the SAME key, while
    /// `invalid_input` means the key cannot serve this request at all and the answer is a
    /// NEW one. The contract separates them on the wire — `Retry-After` rides the
    /// concurrency variant and never the other, "because waiting changes nothing" — so the
    /// header settles it here too, but only for a call that actually carried a key.
    ///
    /// `504` keeps its frequency answer even though its two buckets differ the same way,
    /// and the asymmetry is deliberate rather than an oversight. This PR re-examined `409`
    /// alone; extending the presence test to `504 deadline_exceeded` is a behaviour change
    /// the contract would support — the header is declared on exactly those two responses —
    /// but it belongs to the caller-facing retry work, not to a review-resolution pass. Left
    /// as `providerTimeout` until then.
    private static func fallbackErrorType(
        for status: Int,
        headers: [String: String],
        idempotencyKey: String?
    ) -> RouterErrorType {
        switch status {
        case 400, 422: return .invalidInput
        case 401: return .unauthorized
        case 402: return .insufficientCredits
        case 403: return .forbidden
        case 404: return .modelNotFound
        // Presence, deliberately, rather than a value this SDK could parse: the two
        // readings are not equally safe to guess wrong. Calling a concurrency `409`
        // `invalid_input` sends the caller to a NEW key and a second billable generation;
        // calling it the other way costs one re-send of the same key, which dispatches
        // nothing. So any `Retry-After` at all tips it to the harmless reading.
        //
        // That safety rests entirely on a key being there to re-send, so the key is part
        // of the test. Without one, `concurrency_limit_exceeded` names a remedy the caller
        // cannot perform, and repeating an unkeyed request is the very thing that dispatches
        // a second billable generation — the harm this branch exists to avoid. The contract
        // agrees the case is unreachable: `Retry-After` is documented absent on an unkeyed
        // call, so seeing one here means a proxy added it or the server is wrong.
        // Both halves are tested for a usable value, not merely for being there: the key is
        // already normalised (a blank one is `nil` by this point), and the header is trimmed
        // and checked non-empty like every other string read in this file. A blank
        // `Retry-After:` is not a signal Router sent.
        case 409:
            return idempotencyKey != nil && hasValue(retryAfterHeader, in: headers)
                ? .concurrencyLimitExceeded
                : .invalidInput
        case 429: return .concurrencyLimitExceeded
        case 503: return .serviceUnavailable
        case 504: return .providerTimeout
        default: return .internalError
        }
    }

    // MARK: - Body

    /// The `422` body's `detail[]`, parsed one entry per offending field.
    ///
    /// Every field is tolerated missing or mistyped: an entry that is not an object is
    /// skipped, a missing `msg`/`type` reads as `""`, and a `loc` segment that is neither a
    /// string nor an integer is dropped from the path rather than discarding the entry. The
    /// contract requires all three, so any of these means the response was already wrong —
    /// and losing the whole diagnosis to that is worse than reporting the part that parsed.
    private static func validationErrors(from root: RouterJSON?) -> [RouterValidationErrorDetail] {
        guard let entries = root?["detail"].arrayValue else { return [] }
        return entries.compactMap { entry in
            guard case .object = entry else { return nil }
            let loc: [RouterValidationErrorDetail.LocSegment] =
                (entry["loc"].arrayValue ?? []).compactMap { segment in
                    if let key = segment.stringValue { return .key(key) }
                    if let index = segment.intValue { return .index(index) }
                    return nil
                }
            return RouterValidationErrorDetail(
                loc: loc,
                msg: entry["msg"].stringValue ?? "",
                type: entry["type"].stringValue ?? "",
                ctx: entry["ctx"] == .null ? nil : entry["ctx"],
                input: entry["input"] == .null ? nil : entry["input"]
            )
        }
    }

    /// The human-readable description: the body's `detail` string, else a summary of the
    /// parsed validation entries, else `"HTTP <status>"`.
    ///
    /// The summary is built rather than left empty because `detail` is the one field a
    /// consumer is most likely to surface, and a `422` is precisely the case where the
    /// reason is per-field and the caller has not yet inspected ``RouterError``'s
    /// `validationErrors`.
    private static func detail(
        status: Int,
        root: RouterJSON?,
        validationErrors: [RouterValidationErrorDetail]
    ) -> String {
        if let string = root?["detail"].stringValue, !string.isEmpty {
            return string
        }
        // Tested per entry rather than on the joined string: every entry contributes at
        // least the `": "` separator, so the join is never empty and a body whose entries
        // are all blank would surface `": "` as the diagnosis — worse than the status.
        if validationErrors.contains(where: { !$0.location.isEmpty || !$0.msg.isEmpty }) {
            return validationErrors
                .map { "\($0.location): \($0.msg)" }
                .joined(separator: "; ")
        }
        return "HTTP \(status)"
    }

    // MARK: - Headers

    /// `X-Comfy-Request-Id`, trimmed and capped. Blank reads as absent.
    ///
    /// Measured in Unicode scalars rather than in `Character`s: one extended grapheme
    /// cluster can carry an unbounded run of combining scalars, so a `count`-based cap
    /// admits a megabyte of header under a `count` of 1 — the exact case the cap is here
    /// for.
    private static func requestId(from headers: [String: String]) -> String? {
        guard let raw = headers[requestIdHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let scalars = raw.unicodeScalars
        guard scalars.count > requestIdMaxLength else { return raw }
        return String(String.UnicodeScalarView(scalars.prefix(requestIdMaxLength)))
    }

    /// `Retry-After` as delta-seconds only.
    ///
    /// RFC 9110 also permits an HTTP-date, but Router's contract declares an integer and
    /// this SDK does not carry a date parser for the header. Anything that is not a whole
    /// number of seconds inside ``retryAfterBounds`` — a date, a float, a zero, a negative,
    /// a value past the 24 hours the key itself lives, a value too wide for `Int` at all —
    /// reads as `nil`, i.e. "no advice", which is the safe reading in both directions: an
    /// unusable value must never become a `0` that a caller retries immediately on, nor a
    /// delay a caller sleeping on it never wakes from.
    ///
    /// A value too wide for `Int` and a value merely past the ceiling deliberately land on
    /// the same answer. Both are the same fact — a delay longer than the advice can be acted
    /// on — so reading `"9223372036854775807"` differently from `"9223372036854775808"`
    /// would be an artefact of `Int`'s width rather than anything the contract distinguishes.
    ///
    /// Nothing here can overflow: `Int.init(_: String)` answers `nil` on a value too wide
    /// to represent rather than trapping, so `"99999999999999999999"` is refused at the
    /// parse and never reaches the range test.
    private static func retryAfter(from headers: [String: String]) -> TimeInterval? {
        guard let raw = headers[retryAfterHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Int(raw),
              retryAfterBounds.contains(seconds) else { return nil }
        return TimeInterval(seconds)
    }
}
