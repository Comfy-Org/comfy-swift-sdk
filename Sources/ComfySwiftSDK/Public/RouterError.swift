import Foundation

/// The coarse, machine-readable bucket for a Comfy Router failure.
///
/// Router mirrors this value on the `X-Comfy-Error-Type` response header of
/// *every* error response, so a caller can branch on it without parsing the
/// body — which is the only way to classify the `422`, whose FastAPI-shaped
/// body carries no `error_type` field of its own.
///
/// The set is closed at fifteen values in the vendored contract
/// (`spec/router-openapi.yaml`, `components.schemas.RouterErrorType`), and
/// ``known`` lists them in the spec's declaration order: the six request-tier
/// buckets first, then the nine transport-tier ones. The spec may add a bucket
/// on its own release cycle, so a value this SDK version does not recognise
/// decodes as ``unknown(_:)`` rather than failing — treat it like
/// ``internalError``, which is what the contract itself prescribes.
///
/// `Scripts/contract/check_router_contract.py` fails CI when this table and the
/// spec disagree on membership *or* on order.
public enum RouterErrorType: Sendable, Equatable, Hashable {

    // MARK: Request tier

    /// The request was rejected before it reached the model — a malformed body, an input
    /// the model's own schema does not accept, or an `Idempotency-Key` that cannot serve
    /// this request. `409` for the key cases, `400`/`422` for the others.
    case invalidInput

    /// The provider refused the request on content-policy grounds. The refusal is
    /// deterministic: re-sending the same input will be refused again.
    case contentPolicyViolation

    /// The partner provider reported a failure of its own, or returned a response Router
    /// could not interpret as a result.
    case providerError

    /// The partner provider did not answer within its deadline. This is the *provider*
    /// timing out, never Router's own bound — that is ``deadlineExceeded``, with which it
    /// shares `504`.
    case providerTimeout

    /// The calling workspace does not have enough credits to run the model.
    case insufficientCredits

    /// The `{provider}/{model}` ID names no model Router can run. `detail` carries up to
    /// three suggestions drawn from the models the caller is entitled to see.
    case modelNotFound

    // MARK: Transport tier

    /// The request carried no usable credential.
    case unauthorized

    /// The credential is valid but is not entitled to this model or this operation.
    case forbidden

    /// The workspace already has as many calls in flight as it is allowed; retry once one
    /// of them finishes. On a `409` it instead means another call is already in flight for
    /// this `Idempotency-Key` — re-send the *same* key after `Retry-After` seconds.
    case concurrencyLimitExceeded

    /// The caller closed the connection before Router could return a result. Logged rather
    /// than delivered, and an attribution rather than a billing outcome.
    case clientDisconnected

    /// Router itself failed. It is also the value a client should treat any *unrecognised*
    /// bucket as — see ``unknown(_:)``.
    case internalError

    /// Comfy stopped holding the connection at its own configured bound before an answer
    /// arrived. Nothing about the request was rejected; retry it with the *same*
    /// `Idempotency-Key` to collect the generation that may still be running.
    case deadlineExceeded

    /// Comfy Router is not switched on for this caller yet. Terminal: do not retry, and do
    /// not treat it as an outage. Shares `403` with ``forbidden`` and is not the same thing.
    case notEnabled

    /// A service Comfy Router depends on is temporarily unavailable and the caller did
    /// nothing wrong. It is the one retryable bucket whose condition clears on its own.
    case serviceUnavailable

    /// The caller has spent an allowance measured over a window and must wait for that
    /// window to roll. Shares `429` with ``concurrencyLimitExceeded`` and, unlike it,
    /// does not drain early when the caller's own in-flight calls finish.
    case rateLimited

    /// A bucket this SDK version does not know. Treat like ``internalError``.
    ///
    /// Carries the wire value verbatim so a caller can log or report it.
    case unknown(String)

    /// The wire value of every known bucket, in the vendored spec's declaration order.
    ///
    /// This is the SDK's single source of truth for the mapping in both directions —
    /// ``init(rawValue:)``, ``rawValue`` and ``known`` all read it — and it is the table
    /// `Scripts/contract/check_router_contract.py` parses out of this file between the two
    /// marker comments below. Keep it one bucket per line, with exactly one quoted wire
    /// value on each: the checker's regex depends on that shape, and its order comparison
    /// depends on this list staying in the spec's order.
    // router-error-types:begin
    private static let wire: [(RouterErrorType, String)] = [
        (.invalidInput, "invalid_input"),
        (.contentPolicyViolation, "content_policy_violation"),
        (.providerError, "provider_error"),
        (.providerTimeout, "provider_timeout"),
        (.insufficientCredits, "insufficient_credits"),
        (.modelNotFound, "model_not_found"),
        (.unauthorized, "unauthorized"),
        (.forbidden, "forbidden"),
        (.concurrencyLimitExceeded, "concurrency_limit_exceeded"),
        (.clientDisconnected, "client_disconnected"),
        (.internalError, "internal_error"),
        (.deadlineExceeded, "deadline_exceeded"),
        (.notEnabled, "not_enabled"),
        (.serviceUnavailable, "service_unavailable"),
        (.rateLimited, "rate_limited")
    ]
    // router-error-types:end

    /// Decode a wire value. Anything outside the closed set becomes ``unknown(_:)``
    /// carrying that value verbatim, so a bucket added upstream reaches the caller
    /// instead of failing deserialization.
    public init(rawValue: String) {
        for (bucket, value) in Self.wire where value == rawValue {
            self = bucket
            return
        }
        self = .unknown(rawValue)
    }

    /// The wire value this bucket is sent as.
    ///
    /// For ``unknown(_:)`` this is the value that was received. The `internal_error`
    /// fallback is unreachable for every case declared above — every one of them has a
    /// row in ``wire`` — and is the contract's own prescribed treatment for a bucket a
    /// client cannot place, so a future case added without its row degrades rather
    /// than traps.
    public var rawValue: String {
        if case .unknown(let raw) = self { return raw }
        return Self.wire.first { $0.0 == self }?.1 ?? "internal_error"
    }

    /// Every known bucket, in the vendored spec's declaration order. Used by the tests and
    /// by the contract drift check; ``unknown(_:)`` is deliberately not a member.
    public static let known: [RouterErrorType] = wire.map(\.0)
}

/// One model-level validation failure from a Router `422`, in the FastAPI `detail[]` form.
///
/// ``type`` carries the *specific* provider reason (`missing`, `image_too_small`,
/// `greater_than`, …) — the granularity ``RouterErrorType``'s coarse bucket cannot
/// express. It is an open string rather than an enum because the provider vocabulary grows
/// on the provider's release cycle, not Comfy's.
public struct RouterValidationErrorDetail: Sendable, Equatable {

    /// One segment of a ``loc`` path: an object key, or an index into an array.
    public enum LocSegment: Sendable, Equatable {
        case key(String)
        case index(Int)
    }

    /// Path to the offending field, outermost segment first — `["body", "images", 0]`
    /// becomes `[.key("body"), .key("images"), .index(0)]`.
    public let loc: [LocSegment]

    /// Human-readable description of this single failure.
    public let msg: String

    /// Specific, machine-readable reason, passed through from the provider unchanged.
    public let type: String

    /// The violated bound, carried from the provider verbatim (`{"limit_value": 8}`
    /// alongside `greater_than`). `nil` when the failure carries no bound — an explicit
    /// JSON `null` reads as `nil` too, since the contract's own way of saying "no bound"
    /// is to omit the field.
    public let ctx: RouterJSON?

    /// The offending input value, echoed back verbatim — any JSON type. `nil` when the
    /// provider did not echo it; as with ``ctx``, an explicit JSON `null` reads as `nil`
    /// rather than as ``RouterJSON/null``.
    public let input: RouterJSON?

    /// ``loc`` rendered as a dotted path — `"body.images.0"` — for logs and messages.
    public var location: String {
        loc.map { segment in
            switch segment {
            case .key(let key): return key
            case .index(let index): return String(index)
            }
        }.joined(separator: ".")
    }

    public init(
        loc: [LocSegment],
        msg: String,
        type: String,
        ctx: RouterJSON? = nil,
        input: RouterJSON? = nil
    ) {
        self.loc = loc
        self.msg = msg
        self.type = type
        self.ctx = ctx
        self.input = input
    }
}

/// A Comfy Router model run that failed.
///
/// Every field is populated from one HTTP response by
/// `RouterErrorMapping.routerError(status:headers:body:idempotencyKey:)`, which never
/// throws: an error response that is itself malformed still produces a `RouterError`
/// carrying the status it arrived with.
public struct RouterError: Error, Sendable {

    /// The coarse bucket to branch on. Read from `X-Comfy-Error-Type` when present, then
    /// from the body's `error_type`, then inferred from the status.
    public let errorType: RouterErrorType

    /// The HTTP status the response arrived with.
    public let httpStatus: Int

    /// A human-readable description, safe to surface. The body's `detail` string; or, for
    /// the `422`'s `detail` array, a `"location: msg; location: msg"` summary of
    /// ``validationErrors``; or `"HTTP <status>"` when the body carries neither.
    public let detail: String

    /// The per-field failures from a `422` body. Empty for every other response shape.
    public let validationErrors: [RouterValidationErrorDetail]

    /// The `X-Comfy-Request-Id` of the call — the id to quote in a support request. It is
    /// the same value written into the call's usage/audit event.
    public let requestId: String?

    /// The `Retry-After` delay, in seconds. Only a non-negative integer count of seconds is
    /// accepted; an HTTP-date form (which Router does not send) reads as `nil`.
    public let retryAfter: TimeInterval?

    /// The `Idempotency-Key` the call was made under. Re-sending that key is what collects
    /// an in-flight generation on a `409 concurrency_limit_exceeded` or a
    /// `504 deadline_exceeded`.
    public let idempotencyKey: String

    /// Whether the response was served from an `Idempotency-Key`'s record rather than by
    /// running the model again — `Idempotent-Replayed` is sent only when true, so this is
    /// its presence.
    public let replayed: Bool

    public init(
        errorType: RouterErrorType,
        httpStatus: Int,
        detail: String,
        validationErrors: [RouterValidationErrorDetail] = [],
        requestId: String? = nil,
        retryAfter: TimeInterval? = nil,
        idempotencyKey: String,
        replayed: Bool = false
    ) {
        self.errorType = errorType
        self.httpStatus = httpStatus
        self.detail = detail
        self.validationErrors = validationErrors
        self.requestId = requestId
        self.retryAfter = retryAfter
        self.idempotencyKey = idempotencyKey
        self.replayed = replayed
    }
}
