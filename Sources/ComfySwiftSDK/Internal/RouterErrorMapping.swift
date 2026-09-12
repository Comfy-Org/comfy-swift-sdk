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

    /// Upper bound, in Unicode scalars, on a stored `X-Comfy-Request-Id`. The contract
    /// declares a UUID, so a value this long is already a server bug or a hostile response;
    /// the cap keeps it out of logs and error strings at an unbounded size.
    private static let requestIdMaxLength = 128

    /// Upper bound, in Unicode scalars, on a stored `detail`.
    ///
    /// `detail` is response-controlled free text that the transport copies out of the body and
    /// hands to the caller, who is likely to surface or log it. Nothing in the contract bounds
    /// it, so a misconfigured or hostile host can answer an error with an arbitrarily large
    /// `detail` string and have the SDK retain it for the lifetime of the error. 4 KiB is far
    /// past any genuine diagnosis while keeping the pathological case bounded.
    ///
    /// This is the ERROR path only. A successful run's body is deliberately left uncapped —
    /// those bytes are the output the caller has already been charged for, and truncating them
    /// would turn a paid, successful generation into a partial one.
    private static let detailMaxLength = 4096

    /// Upper bound on entries parsed out of a `422` body's `detail[]`.
    private static let validationErrorsMaxCount = 128

    /// The ``RouterErrorType/unknown(_:)`` payload for a status the contract declares no bucket
    /// for.
    ///
    /// Prefixed with `comfy-sdk/` because `unknown(_:)` otherwise carries a value the SERVER
    /// sent, verbatim. Synthesising a bare `http_202` into that field would put an SDK-invented
    /// token where a caller is entitled to read a server-named one — and would collide outright
    /// if a response ever named `http_202` itself. The prefix cannot appear in a header value
    /// the contract permits, so the two origins stay distinguishable.
    private static func undeclaredStatusMarker(_ status: Int) -> String {
        "comfy-sdk/undeclared_status_\(status)"
    }

    /// Upper bound, in Unicode scalars, on a stored ``RouterErrorType/unknown(_:)`` raw value.
    ///
    /// The third response-controlled string on the same error, after `detail` and `requestId`.
    /// An unrecognised `X-Comfy-Error-Type` — or the body's `error_type`, which is parsed out of
    /// the body and so bounded by nothing — is stored verbatim and exposed through the public
    /// `rawValue`, so without this a tiny `detail` could still ship with a megabyte-sized error
    /// bucket. `SDKLog.loggableType` already folds `.unknown` to a fixed string before emitting
    /// it, which is the same judgement applied one layer down.
    private static let errorTypeMaxLength = 128

    /// `value` truncated to ``detailMaxLength`` scalars.
    ///
    /// Measured in Unicode scalars for the same reason the request id is: one extended grapheme
    /// cluster can carry an unbounded run of combining scalars, so a `count`-based cap admits a
    /// megabyte of text under a `count` of 1.
    private static func capped(_ value: String, to maxLength: Int = detailMaxLength) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count > maxLength else { return value }
        return String(String.UnicodeScalarView(scalars.prefix(maxLength)))
    }

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
    ///     original generation.
    static func routerError(
        status: Int,
        headers: [String: String],
        body: Data,
        idempotencyKey: String
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

    /// The two success-path response headers, read with exactly the rules ``routerError(status:headers:body:idempotencyKey:)``
    /// applies on the failure path.
    ///
    /// A `2xx` carries the same `X-Comfy-Request-Id` and the same `Idempotent-Replayed` as an
    /// error response does, and they have to be read the same way — case-insensitively, with
    /// the request id trimmed and capped — or a run that succeeded and a run that failed would
    /// report the support id differently for byte-identical headers. Sharing the private
    /// helpers below is the point: a second copy in the transport is where that divergence
    /// would start.
    ///
    /// - Returns: The capped `X-Comfy-Request-Id` (`nil` when absent or blank) and whether
    ///   `Idempotent-Replayed` was present at all — Router sends it only when the answer came
    ///   from the key's record, so presence *is* the value.
    static func successMetadata(headers: [String: String]) -> (requestId: String?, replayed: Bool) {
        let normalizedHeaders = normalize(headers)
        return (
            requestId: requestId(from: normalizedHeaders),
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
        // Capped on both channels: a recognised bucket is one of a short closed set and is
        // unaffected, so the cap only ever bites an `.unknown(_)` raw value — which is exactly
        // the response-controlled string it is here to bound.
        if let header = headers[errorTypeHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty {
            return RouterErrorType(rawValue: capped(header, to: errorTypeMaxLength))
        }
        if let bodyValue = root?["error_type"].stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bodyValue.isEmpty {
            return RouterErrorType(rawValue: capped(bodyValue, to: errorTypeMaxLength))
        }
        return fallbackErrorType(for: status)
    }

    /// The bucket a status implies when neither the header nor the body named one.
    ///
    /// A status maps to the bucket the contract pairs it with on the model-run route. Where
    /// one status carries two buckets, the more common one is chosen — `403` reads as
    /// `forbidden` rather than `not_enabled`, `429` as `concurrencyLimitExceeded` rather
    /// than `rateLimited`, `504` as `providerTimeout` rather than `deadlineExceeded` — and
    /// the ambiguity is why Router sends the header in the first place. Anything
    /// unrecognised, `500` included, is `internalError`.
    private static func fallbackErrorType(for status: Int) -> RouterErrorType {
        switch status {
        // A `2xx` that is not the declared `200`, or a `3xx` handed back by
        // `RouterRedirectRefusal` rather than followed. Neither is a status the contract pairs
        // with a bucket, and `.internalError` ("Router itself failed") would be close to the
        // opposite of what a `202 Accepted` or a `307` means — a caller whose handling for that
        // bucket is "report it and start over with a fresh key" would pay for the same
        // generation twice. `.unknown` is the honest bucket for a response the contract does
        // not declare; ``RouterError`` reports the number on `httpStatus` besides.
        case 200..<400: return .unknown(undeclaredStatusMarker(status))
        case 400, 409, 422: return .invalidInput
        case 401: return .unauthorized
        case 402: return .insufficientCredits
        case 403: return .forbidden
        case 404: return .modelNotFound
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
        // Bounded before parsing. Each entry retains its `msg`, `type` and `loc` plus whole
        // `ctx`/`input` JSON subtrees on the returned error, so an unbounded entry count is an
        // unbounded, response-controlled retention — `{"detail":[{},{},…]}` repeated a million
        // times. A genuine `422` names the fields that failed validation; no real request has
        // more than a handful, let alone this many.
        return entries.prefix(validationErrorsMaxCount).compactMap { entry in
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
            return capped(string)
        }
        // Tested per entry rather than on the joined string: every entry contributes at
        // least the `": "` separator, so the join is never empty and a body whose entries
        // are all blank would surface `": "` as the diagnosis — worse than the status.
        if validationErrors.contains(where: { !$0.location.isEmpty || !$0.msg.isEmpty }) {
            // Capped like the string branch above, and for the same reason. This is the shape
            // the contract actually declares for a `422`, so leaving it uncapped would have
            // meant the cap covered only the branch a conforming `422` never takes: one entry
            // with a megabyte `msg`, or a million empty entries, both land here.
            return capped(
                validationErrors
                    .map { "\($0.location): \($0.msg)" }
                    .joined(separator: "; ")
            )
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
    /// RFC 9110 also permits an HTTP-date, but Router's contract declares an integer with a
    /// minimum of 1 and this SDK does not carry a date parser for the header. Anything that
    /// is not a whole number of seconds at or above that minimum — a date, a float, a zero,
    /// a negative — reads as `nil`, i.e. "no advice", which is the safe reading: an
    /// unusable value must never become a `0` that a caller retries immediately on.
    private static func retryAfter(from headers: [String: String]) -> TimeInterval? {
        guard let raw = headers[retryAfterHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Int(raw),
              seconds >= 1 else { return nil }
        return TimeInterval(seconds)
    }
}
