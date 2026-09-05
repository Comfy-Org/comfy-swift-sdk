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

    /// Upper bound on a stored `X-Comfy-Request-Id`. The contract declares a UUID, so a
    /// value this long is already a server bug or a hostile response; the cap keeps it out
    /// of logs and error strings at an unbounded size.
    private static let requestIdMaxLength = 128

    /// Build the ``RouterError`` for one failed Router response.
    ///
    /// - Parameters:
    ///   - status: The HTTP status the response arrived with.
    ///   - headers: The response headers. Names are matched case-insensitively; a dictionary
    ///     carrying the same name in two different casings resolves to one of them
    ///     arbitrarily, since `Dictionary` has no defined iteration order.
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

    // MARK: - Inputs

    /// Lowercase every header name once, so each lookup below is a plain dictionary hit.
    private static func normalize(_ headers: [String: String]) -> [String: String] {
        var normalized: [String: String] = [:]
        normalized.reserveCapacity(headers.count)
        for (name, value) in headers {
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
        if !validationErrors.isEmpty {
            let summary = validationErrors
                .map { "\($0.location): \($0.msg)" }
                .joined(separator: "; ")
            if !summary.isEmpty { return summary }
        }
        return "HTTP \(status)"
    }

    // MARK: - Headers

    /// `X-Comfy-Request-Id`, trimmed and capped. Blank reads as absent.
    private static func requestId(from headers: [String: String]) -> String? {
        guard let raw = headers[requestIdHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw.count > requestIdMaxLength ? String(raw.prefix(requestIdMaxLength)) : raw
    }

    /// `Retry-After` as delta-seconds only.
    ///
    /// RFC 9110 also permits an HTTP-date, but Router's contract declares an integer with a
    /// minimum of 1 and this SDK does not carry a date parser for the header. Anything that
    /// is not a whole non-negative number of seconds — a date, a float, a negative — reads
    /// as `nil`, i.e. "no advice", which is the safe reading: an unparsed value must never
    /// become a `0` that a caller retries immediately on.
    private static func retryAfter(from headers: [String: String]) -> TimeInterval? {
        guard let raw = headers[retryAfterHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let seconds = Int(raw),
              seconds >= 0 else { return nil }
        return TimeInterval(seconds)
    }
}
