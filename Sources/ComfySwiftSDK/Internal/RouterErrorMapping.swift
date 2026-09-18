import Foundation

extension CharacterSet {
    /// HTTP optional whitespace (RFC 9110 OWS): space and horizontal tab, and nothing else.
    ///
    /// Deliberately not `.whitespacesAndNewlines`, which also strips NBSP, vertical tab,
    /// form feed and the Unicode separators — characters that are ordinary content inside a
    /// header value, not padding around it.
    static let httpOptionalWhitespace = CharacterSet(charactersIn: " \t")
}

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
    private static let creditsUsedHeader = "x-comfy-credits-used"

    /// The window a `Retry-After` is honoured over **on the two collect answers**, in
    /// seconds. Outside it the header is dropped — this SDK reports no advice rather than
    /// advice it can show is unusable.
    ///
    /// This ceiling applies only where ``collectsWithSameKey(status:declared:)`` holds. Its
    /// whole justification is the life of an `Idempotency-Key`, so it has nothing to say
    /// about a delay that is ordinary backoff: a `429 rate_limited` or a `503` may
    /// legitimately ask for a multi-day wait, and those are bounded far more loosely, by
    /// ``ordinaryBackoffBounds``. The floor, the contract's own `minimum: 1`, applies
    /// everywhere — a zero or a negative is not a shorter wait, it is an unusable value.
    ///
    /// On a collect answer the advice means one thing: wait, then re-send the SAME key to
    /// collect the generation still running. Router holds that key for 24 hours.
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

    /// Whether this answer's `Retry-After` means "re-send the SAME `Idempotency-Key` to
    /// collect the generation still running", rather than plain backoff.
    ///
    /// These are the only two answers the contract declares the header on, and the test is
    /// on the *answer* — status and bucket together — not on the status alone, because the
    /// status does not determine the meaning. `409` carries `invalid_input` as well, where
    /// the key is what the server refused and a delay would invite re-sending it; `504`
    /// carries `provider_timeout`, where nothing is in flight to collect; and
    /// `concurrency_limit_exceeded` on a `429` is the workspace's in-flight limit, which has
    /// no key in it at all. Only these two pairings carry the collect semantics that make
    /// the key-lifetime ceiling, and the no-key suppression, apply.
    ///
    /// `declared` is the bucket Router *named* on the wire, and is `nil` when it named none.
    /// It is deliberately not the resolved ``RouterErrorType``: the fallback answers
    /// `.invalidInput` for a bare unkeyed `409` precisely because the key is absent, so
    /// deriving the collect test from it would disable the no-key suppression in exactly the
    /// case that suppression exists for.
    ///
    /// An *undeclared* `409`/`504` counts as a collect answer. The contract puts
    /// `Retry-After` on a `409` only for `concurrency_limit_exceeded` and on a `504` only
    /// for `deadline_exceeded`, so a delay on a bare one is most likely that answer with its
    /// header lost — and being wrong costs withheld advice, while the other way round costs
    /// a second billable generation.
    /// `.unknown` is treated like an undeclared bucket, not like a named non-collect one.
    /// `RouterErrorType(rawValue:)` never answers `nil`, so an unrecognised, future,
    /// case-variant or comma-joined header arrives here as `.unknown(raw)` — which would
    /// otherwise re-open, through that door, both harms the undeclared branch closes.
    private static func collectsWithSameKey(status: Int, declared: RouterErrorType?) -> Bool {
        guard status == 409 || status == 504 else { return false }
        guard let declared else { return true }
        if case .unknown = declared { return true }
        // Each status with its own bucket, never the cross product: a
        // `504 concurrency_limit_exceeded` or a `409 deadline_exceeded` is not a collect
        // answer, and the contract pairs each header with exactly one of them.
        return (status == 409 && declared == .concurrencyLimitExceeded)
            || (status == 504 && declared == .deadlineExceeded)
    }

    /// The window an ordinary-backoff `Retry-After` is honoured over, in seconds.
    ///
    /// Seven days. No key is involved on these answers, so the key-lifetime ceiling does not
    /// apply and a multi-day wait is a legitimate instruction — but the value is
    /// server-controlled and an unbounded one is not actionable: a caller converting it to
    /// nanoseconds traps, and one that does not convert simply never retries. Beyond a week
    /// the value is a server bug rather than advice, and `nil` leaves the caller on its own
    /// schedule.
    private static let ordinaryBackoffBounds = 1 ... 604_800

    /// Upper bound, in Unicode scalars, on a stored `X-Comfy-Request-Id`. The contract
    /// declares a UUID, so a value this long is already a server bug or a hostile response;
    /// the cap keeps it out of logs and error strings at an unbounded size.
    private static let requestIdMaxLength = 128

    /// Upper bound, in Unicode scalars, on a stored `X-Comfy-Credits-Used`.
    ///
    /// The value is a decimal cost figure at up to two places, so nothing legitimate comes
    /// close to 32 scalars. Past the bound the value is DROPPED rather than truncated, which
    /// is the opposite of ``requestIdMaxLength``'s policy and deliberately so: truncating an
    /// opaque id leaves a shortened id, while truncating a number leaves a *different number*
    /// — `1000` clipped to `10` is a plausible-looking figure that is wrong by two orders of
    /// magnitude, and a caller reconciling money against it has no way to tell.
    private static let creditsUsedMaxLength = 32

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

    /// Upper bound, in Unicode scalars, on each string field retained from one `422` entry.
    private static let fieldMaxLength = 1024

    /// Upper bound on `loc` segments retained from one `422` entry.
    private static let locSegmentsMaxCount = 32

    /// Upper bound on the node count of a retained `ctx`/`input` subtree.
    private static let subtreeMaxNodes = 256

    /// `value` if it is small enough to retain, `nil` if it is absent or oversized.
    private static func boundedSubtree(_ value: RouterJSON) -> RouterJSON? {
        guard value != .null, nodeCount(value, limit: subtreeMaxNodes) <= subtreeMaxNodes else {
            return nil
        }
        return value
    }

    /// The retention cost of `value`, counted no further than `limit`.
    ///
    /// Two things this deliberately does that a plain node count does not:
    ///
    /// - **It refuses to recurse once the budget is spent.** The guard is on ENTRY, not after a
    ///   child returns. Checking only on the way out bounds breadth while leaving depth
    ///   unbounded, so a `ctx` of 100k nested single-element arrays would be descended one
    ///   stack frame per level however small `limit` was — the opposite of a bounded walk, and
    ///   a stack overflow on a response-controlled input.
    /// - **It charges a string by its length, not as one node.** Counting every scalar leaf as
    ///   `1` would repeat the mistake this bound exists to fix one level down: `{"blob": "<64
    ///   MiB>"}` is a two-node subtree that clears any node limit while parking the whole 64
    ///   MiB on the error. A string costs a scalar-per-``fieldMaxLength`` slice of the budget,
    ///   so size is what is actually bounded.
    private static func nodeCount(_ value: RouterJSON, limit: Int) -> Int {
        guard limit > 0 else { return 1 }

        switch value {
        case .array(let elements):
            var total = 1
            for element in elements {
                total += nodeCount(element, limit: limit - total)
                if total > limit { return total }
            }
            return total
        case .object(let members):
            var total = 1
            for (key, member) in members {
                total += stringCost(key) + nodeCount(member, limit: limit - total)
                if total > limit { return total }
            }
            return total
        case .string(let text):
            return stringCost(text)
        default:
            return 1
        }
    }

    /// What one string costs against a subtree budget: one unit per ``fieldMaxLength`` scalars,
    /// minimum one, so a short string is a single node and a huge one cannot hide as one.
    ///
    /// CEILING division, not floor. Flooring let every string up to `2 * fieldMaxLength - 1`
    /// scalars cost a single unit, so an array of 255 of them passed a 256-unit budget while
    /// retaining roughly double what the bound intends.
    private static func stringCost(_ value: String) -> Int {
        let scalars = value.unicodeScalars.count
        return max(1, (scalars + fieldMaxLength - 1) / fieldMaxLength)
    }

    /// The ``RouterErrorType/unknown(_:)`` payload for a status the contract declares no bucket
    /// for.
    ///
    /// Prefixed with ``sdkMarkerPrefix`` because `unknown(_:)` otherwise carries a value the
    /// SERVER sent, verbatim. Synthesising a bare `http_202` into that field would put an
    /// SDK-invented token where a caller is entitled to read a server-named one, and would
    /// collide outright if a response ever named `http_202` itself.
    ///
    /// The prefix only keeps the two origins apart if a server cannot also produce it, which
    /// is why `errorType(status:headers:root:)` refuses a server value carrying it.
    private static func undeclaredStatusMarker(_ status: Int) -> String {
        "\(sdkMarkerPrefix)undeclared_status_\(status)"
    }

    /// Marks a ``RouterErrorType/unknown(_:)`` payload as SDK-synthesised rather than
    /// server-sent. Reserved: a server value carrying it is refused rather than stored.
    private static let sdkMarkerPrefix = "comfy-sdk/"

    /// Whether a server-supplied bucket name may be stored as sent.
    ///
    /// Case-insensitive, because the reservation has to hold against a host that varies the
    /// casing to slip past it. A refused value falls through to the next source, exactly as a
    /// blank one does — the response named no bucket this SDK will repeat.
    static func isServerNameable(_ value: String) -> Bool {
        // Only the marker-length prefix is folded. Case-folding the whole value would force a
        // second full-size copy and scan of an arbitrarily large body `error_type` before
        // either call site has applied its 128-scalar cap.
        !value.prefix(sdkMarkerPrefix.count).lowercased().hasPrefix(sdkMarkerPrefix)
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
        let resolvedKey = RouterError.normalizedIdempotencyKey(idempotencyKey)

        let validationErrors = validationErrors(from: root)
        // The bucket Router actually named, kept separate from the resolved one. The
        // collect test below must not consult the fallback: the fallback downgrades a bare
        // unkeyed `409` to `.invalidInput` *because* the key is `nil`, so feeding that back
        // in would switch the no-key suppression off in exactly the case it exists for.
        let declared = declaredErrorType(headers: normalizedHeaders, root: root)
        let errorType = declared ?? fallbackErrorType(
            for: status,
            headers: normalizedHeaders,
            idempotencyKey: resolvedKey
        )

        return RouterError(
            errorType: errorType,
            httpStatus: status,
            detail: detail(status: status, root: root, validationErrors: validationErrors),
            validationErrors: validationErrors,
            requestId: requestId(from: normalizedHeaders),
            retryAfter: retryAfter(
                from: normalizedHeaders,
                collectsWithSameKey: collectsWithSameKey(status: status, declared: declared),
                idempotencyKey: resolvedKey
            ),
            idempotencyKey: resolvedKey,
            // A value that actually says `true`, and only where the claim can hold.
            // `Idempotent-Replayed` asserts "served from the key's record rather than run
            // again" — billing-relevant — so a blank header, a `false` from a proxy, and a
            // call that carried no key must none of them produce `true`.
            replayed: resolvedKey != nil && isTrue(replayedHeader, in: normalizedHeaders)
        )
    }

    /// The success-path response headers, read with exactly the rules ``routerError(status:headers:body:idempotencyKey:)``
    /// applies on the failure path.
    ///
    /// A `2xx` carries the same `X-Comfy-Request-Id` and the same `Idempotent-Replayed` as an
    /// error response does, and they have to be read the same way — case-insensitively, with
    /// the request id trimmed and capped — or a run that succeeded and a run that failed would
    /// report the support id differently for byte-identical headers. Sharing the private
    /// helpers below is the point: a second copy in the transport is where that divergence
    /// would start.
    ///
    /// - Returns: The capped `X-Comfy-Request-Id` (`nil` when absent or blank), whether
    ///   `Idempotent-Replayed` was present at all — Router sends it only when the answer came
    ///   from the key's record, so presence *is* the value — and the verbatim
    ///   `X-Comfy-Credits-Used` (`nil` when absent, blank or unusable).
    static func successMetadata(
        headers: [String: String]
    ) -> (requestId: String?, replayed: Bool, creditsUsed: String?) {
        let normalizedHeaders = normalize(headers)
        return (
            requestId: requestId(from: normalizedHeaders),
            replayed: normalizedHeaders[replayedHeader] != nil,
            creditsUsed: creditsUsed(from: normalizedHeaders)
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
        guard let raw = headers[name]?.trimmingCharacters(in: .httpOptionalWhitespace) else {
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

    /// Largest error body this will parse.
    ///
    /// Parsing builds a `JSONSerialization` object graph plus a whole `RouterJSON` tree, so an
    /// oversized error body costs several multiples of itself in peak allocation to extract a
    /// `detail` that is then capped at 4 KiB anyway. Nothing legitimate needs an unbounded
    /// error response: the contract's error bodies are a short `detail` and, for a `422`, a
    /// list of field failures.
    ///
    /// This bounds the PARSE, not the transfer. `session.data(for:delegate:)` has already
    /// buffered the body by the time this runs, so the buffer itself is not bounded here —
    /// doing that needs a streaming read with a byte limit, which is a restructure of the send
    /// path rather than a change to this classifier. Over the cap the error degrades to its
    /// status-derived form, which is exactly what a non-JSON body already does.
    private static let parsedBodyMaxBytes = 1 << 20

    /// Deepest JSON nesting this will parse.
    ///
    /// `RouterJSON(any:)` walks the parsed graph RECURSIVELY, one stack frame per level, and
    /// `JSONSerialization` happily accepts nesting far deeper than that walk survives on the
    /// small stacks the SDK's work actually runs on — measured: a 500-deep body crashes the
    /// process inside that walk, before any cap in this file has run. So depth has to be
    /// refused from the RAW BYTES, before anything is parsed or built.
    ///
    /// 64 is far past any real Router error body — the deepest the contract describes is a
    /// `422`'s `detail[].ctx`, three or four levels — while leaving no room for a hostile one.
    static let parsedBodyMaxDepth = 64

    /// Deepest bracket nesting in `body`, counted from the bytes and stopped at `limit`.
    ///
    /// Byte-level and quote-aware: a `[` inside a string literal is text, not nesting, and an
    /// escaped quote does not end the string. No allocation and one pass, because this runs
    /// before the SDK has agreed to spend anything on the response.
    static func exceedsDepth(_ body: Data, limit: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in body {
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }       // backslash
                else if byte == 0x22 { inString = false }     // quote
                continue
            }
            switch byte {
            case 0x22: inString = true                        // quote
            case 0x5B, 0x7B:                                  // [ {
                depth += 1
                if depth > limit { return true }
            case 0x5D, 0x7D: depth -= 1                       // ] }
            default: break
            }
        }
        return false
    }

    /// The body parsed as a JSON object, or `nil` when it is empty, oversized, not JSON, or not
    /// an object at the top level. Both Router error bodies are objects.
    private static func jsonObject(from body: Data) -> RouterJSON? {
        guard !body.isEmpty,
              body.count <= parsedBodyMaxBytes,
              !exceedsDepth(body, limit: parsedBodyMaxDepth),
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
    private static func declaredErrorType(
        headers: [String: String],
        root: RouterJSON?
    ) -> RouterErrorType? {
        // Capped on both channels: a recognised bucket is one of a short closed set and is
        // unaffected, so the cap only ever bites an `.unknown(_)` raw value — which is exactly
        // the response-controlled string it is here to bound.
        // `isServerNameable` is what makes ``sdkMarkerPrefix`` actually reserved. Without it a
        // hostile host could send `X-Comfy-Error-Type: comfy-sdk/undeclared_status_202` and
        // produce an `.unknown` payload byte-identical to the SDK's own synthesised marker —
        // on any status — which is precisely the confusion the prefix exists to prevent.
        if let header = headers[errorTypeHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !header.isEmpty, isServerNameable(header) {
            return RouterErrorType(rawValue: capped(header, to: errorTypeMaxLength))
        }
        if let bodyValue = root?["error_type"].stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bodyValue.isEmpty, isServerNameable(bodyValue) {
            return RouterErrorType(rawValue: capped(bodyValue, to: errorTypeMaxLength))
        }
        return nil
    }

    /// The bucket a status implies when neither the header nor the body named one.
    ///
    /// A status maps to the bucket the contract pairs it with on the model-run route. Where
    /// one status carries two buckets, the more common one is chosen — `403` reads as
    /// `forbidden` rather than `not_enabled`, `429` as `concurrencyLimitExceeded` rather
    /// than `rateLimited`, `504` as `providerTimeout` rather than `deadlineExceeded` — and
    /// the ambiguity is why Router sends the header in the first place. Anything
    /// unrecognised at `4xx` or above, `500` included, is `internalError`; an undeclared
    /// `2xx`/`3xx` is `.unknown` instead, for the reason given on that case.
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
        // A `2xx` above the declared `200`, or a `3xx` handed back by
        // `RouterRedirectRefusal` rather than followed. Neither is a status the contract pairs
        // with a bucket, and `.internalError` ("Router itself failed") would be close to the
        // opposite of what a `202 Accepted` or a `307` means — a caller whose handling for that
        // bucket is "report it and start over with a fresh key" would pay for the same
        // generation twice. `.unknown` is the honest bucket for a response the contract does
        // not declare; ``RouterError`` reports the number on `httpStatus` besides.
        case 201..<400: return .unknown(undeclaredStatusMarker(status))
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
        // Bounded in COUNT and in CONTENT — a count cap alone is not a content cap, and 128
        // entries each carrying an 8 MiB `msg` and a large `ctx` subtree is still unbounded
        // retention on a public property, sitting behind a `detail` that looks small.
        //
        // This bounds what the error RETAINS, which is what outlives the call. It does not
        // reduce peak allocation: `jsonObject(from:)` has already parsed the whole body into a
        // `RouterJSON` tree before this runs. Capping the body itself is the separate question
        // of how much response to accept at all, and is deliberately not decided here.
        return entries.prefix(validationErrorsMaxCount).compactMap { entry in
            guard case .object = entry else { return nil }
            let loc: [RouterValidationErrorDetail.LocSegment] =
                (entry["loc"].arrayValue ?? [])
                    .prefix(locSegmentsMaxCount)
                    .compactMap { segment in
                        if let key = segment.stringValue { return .key(capped(key, to: fieldMaxLength)) }
                        if let index = segment.intValue { return .index(index) }
                        return nil
                    }
            return RouterValidationErrorDetail(
                loc: loc,
                msg: capped(entry["msg"].stringValue ?? "", to: fieldMaxLength),
                type: capped(entry["type"].stringValue ?? "", to: fieldMaxLength),
                // `ctx` and `input` are arbitrary JSON the server echoes back, so they are the
                // one part of an entry with no natural bound. Dropped rather than truncated
                // when oversized: half a JSON tree is not a more useful diagnosis than none,
                // and `detail` still carries the message.
                ctx: boundedSubtree(entry["ctx"]),
                input: boundedSubtree(entry["input"])
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
        // Sanitised HERE rather than in each renderer. The id reaches `RouterError`,
        // `RouterRunResult` and any caller that logs it directly, and the contract declares a
        // UUID — so a line break in it is a hostile response forging a log line, whichever of
        // those three printed it.
        let scalars = raw.unicodeScalars.prefix(requestIdMaxLength).map { scalar in
            unsafeInLogLine.contains(scalar) ? "." : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// `X-Comfy-Credits-Used`, trimmed and handed over verbatim. Blank reads as absent.
    ///
    /// Not parsed and not validated: the value is Router's own price for the run, and this SDK
    /// has no business deciding that a figure it does not recognise was never reported. A
    /// caller that needs arithmetic parses it with `Decimal(string:)` and handles the `nil`.
    ///
    /// What it *will* refuse is a value it cannot hand over faithfully, because every
    /// alternative to refusing invents a number:
    ///
    /// - Over ``creditsUsedMaxLength`` it is dropped rather than truncated — see that
    ///   declaration.
    /// - A value carrying a control character or a line break is dropped rather than scrubbed.
    ///   ``requestId(from:)`` replaces those scalars with `.` because an id is opaque, but the
    ///   same substitution turns `1\n2` into the perfectly plausible `1.2`. A forged cost
    ///   figure is worse than no cost figure, and this is also the header's log-injection
    ///   guard: the value reaches ``RouterRunResult`` and any caller that logs it.
    ///
    /// Both refusals are indistinguishable from "not reported" to the caller, which the
    /// property's documentation already tells them to treat as "no figure", never as "free".
    private static func creditsUsed(from headers: [String: String]) -> String? {
        guard let raw = headers[creditsUsedHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.unicodeScalars.count <= creditsUsedMaxLength,
              !raw.unicodeScalars.contains(where: unsafeInLogLine.contains) else { return nil }
        return raw
    }

    /// Scalars that must not reach a log line: the control categories plus U+2028/U+2029,
    /// which `CharacterSet.controlCharacters` excludes but every log viewer renders as a break.
    private static let unsafeInLogLine = CharacterSet.controlCharacters.union(.newlines)

    /// `Retry-After` as delta-seconds only.
    ///
    /// RFC 9110 also permits an HTTP-date, but Router's contract declares an integer and
    /// this SDK does not carry a date parser for the header. Anything that is not a whole
    /// number of seconds — a date, a float, a zero, a negative, a value too wide for `Int`
    /// at all — reads as `nil`, i.e. "no advice", which is the safe reading in both
    /// directions: an unusable value must never become a `0` that a caller retries
    /// immediately on, nor a delay a caller sleeping on it never wakes from.
    ///
    /// Which ceiling then applies depends on what the answer *means*, and the two differ by
    /// two orders of magnitude. On a collect answer it is ``retryAfterBounds`` — the life of
    /// the key the caller is being told to re-send. On ordinary backoff it is
    /// ``ordinaryBackoffBounds``, a loose sanity bound with no key behind it. Past either,
    /// the value is dropped rather than clamped, for the reasons on those two declarations.
    ///
    /// A value too wide for `Int` and one merely past the applicable ceiling land on the
    /// same answer, so reading `"9223372036854775807"` differently from
    /// `"9223372036854775808"` is never an artefact of `Int`'s width.
    ///
    /// Nothing here can overflow: `Int.init(_: String)` answers `nil` on a value too wide
    /// to represent rather than trapping, so `"99999999999999999999"` is refused at the
    /// parse and never reaches the range test.
    private static func retryAfter(
        from headers: [String: String],
        collectsWithSameKey: Bool,
        idempotencyKey: String?
    ) -> TimeInterval? {
        guard let raw = headers[retryAfterHeader]?.trimmingCharacters(in: .httpOptionalWhitespace),
              let seconds = Int(raw),
              seconds >= 1 else { return nil }

        // Ordinary backoff — a `429 rate_limited`, a `503`, a `provider_timeout` `504`.
        // Nothing is being collected and no key is involved, so the key-lifetime ceiling has
        // nothing to say here and a multi-day wait is a legitimate instruction. Dropping one
        // would leave a caller on `retryAfter ?? 0` hammering a server that asked to be left
        // alone.
        //
        // A generous sanity bound still applies. The value is server-controlled, and an
        // unbounded one is not advice a caller can act on: spelling the wait as
        // `Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))` traps on the
        // conversion long before the delay elapses — a crash reachable from a response body,
        // which is the same hazard `RouterJSON.intValue`'s exclusive upper bound exists to
        // exclude.
        guard collectsWithSameKey else {
            return ordinaryBackoffBounds.contains(seconds) ? TimeInterval(seconds) : nil
        }

        // Collect semantics: the delay is only usable if the key survives it, and only if
        // there is a key at all. See ``retryAfterBounds``.
        guard idempotencyKey != nil, retryAfterBounds.contains(seconds) else { return nil }
        return TimeInterval(seconds)
    }

    /// Whether `name` is present and says `true`.
    ///
    /// `Idempotent-Replayed` is a boolean, and the claim it makes — "served from the key's
    /// record rather than run again" — is billing-relevant, so it is parsed rather than
    /// taken on presence: a blank value asserts nothing and a `false` from a proxy or a
    /// buggy server asserts the opposite. Over-claiming tells a caller it was not charged
    /// when it may have been; under-claiming only makes it assume the call ran.
    private static func isTrue(_ name: String, in headers: [String: String]) -> Bool {
        guard let raw = headers[name]?.trimmingCharacters(in: .httpOptionalWhitespace) else {
            return false
        }
        return raw.lowercased() == "true"
    }
}
