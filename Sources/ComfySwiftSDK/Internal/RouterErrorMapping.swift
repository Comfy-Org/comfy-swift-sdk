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

    /// The window a `Retry-After` is honoured over, in seconds.
    ///
    /// The floor is the contract's own `minimum: 1`. Below it there is no advice to carry —
    /// a zero or a negative is not a shorter wait, it is an unusable value — so the header
    /// is dropped.
    ///
    /// The ceiling is the life of an `Idempotency-Key`, which Router holds for 24 hours: on
    /// a keyed run, waiting longer than the key itself lives is self-defeating, because past
    /// it there is nothing left to collect.
    ///
    /// Above the ceiling the value is **clamped, not dropped**. The ceiling is this SDK's
    /// inference and not the contract's — the schema declares `minimum: 1` and no maximum —
    /// and the key-lifetime argument behind it does not hold for `429 rate_limited` or
    /// `503 service_unavailable`, which carry no key and where a multi-day backoff is a
    /// legitimate instruction. Dropping one would answer `nil`, "no advice", to a server
    /// that asked explicitly to be left alone, and a caller reading `retryAfter ?? 0` would
    /// then retry *immediately* — the one outcome this file says must never happen. Clamping
    /// keeps the direction of the server's intent and still bounds the sleep to a delay the
    /// caller wakes from, which is the other half of the same guarantee.
    private static let retryAfterBounds = 1 ... 86_400

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

        let validationErrors = validationErrors(from: root)
        let errorType = errorType(
            status: status,
            headers: normalizedHeaders,
            root: root
        )

        return RouterError(
            errorType: errorType,
            httpStatus: status,
            detail: detail(status: status, root: root, validationErrors: validationErrors),
            validationErrors: validationErrors,
            requestId: requestId(from: normalizedHeaders),
            retryAfter: retryAfter(from: normalizedHeaders),
            idempotencyKey: idempotencyKey,
            replayed: normalizedHeaders[replayedHeader] != nil
        )
    }

    // MARK: - Inputs

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
        root: RouterJSON?
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
        return fallbackErrorType(for: status, headers: headers)
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
    /// header settles it here too.
    private static func fallbackErrorType(
        for status: Int,
        headers: [String: String]
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
        case 409: return headers[retryAfterHeader] == nil ? .invalidInput : .concurrencyLimitExceeded
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

    /// `Retry-After` as delta-seconds, clamped to ``retryAfterBounds``.
    ///
    /// RFC 9110 also permits an HTTP-date, but Router's contract declares an integer and
    /// this SDK does not carry a date parser for the header. Anything that is not a whole
    /// number of seconds at or above the contract's `minimum: 1` — a date, a float, a zero,
    /// a negative, a value too wide for `Int` at all — reads as `nil`, i.e. "no advice",
    /// because an unusable value must never become a `0` that a caller retries immediately
    /// on.
    ///
    /// A parseable value *above* the ceiling is clamped rather than dropped, so an explicit
    /// long backoff never degrades into "no advice" and from there into the immediate retry
    /// that "no advice" invites. See ``retryAfterBounds``.
    ///
    /// Nothing here can overflow: `Int.init(_: String)` answers `nil` on a value too wide
    /// to represent rather than trapping, so `"99999999999999999999"` is refused at the
    /// parse and never reaches the bounds test.
    private static func retryAfter(from headers: [String: String]) -> TimeInterval? {
        guard let raw = headers[retryAfterHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Int(raw),
              seconds >= retryAfterBounds.lowerBound else { return nil }
        return TimeInterval(min(seconds, retryAfterBounds.upperBound))
    }
}
