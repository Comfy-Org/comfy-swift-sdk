import Foundation

/// The SDK's exhaustive error taxonomy. Every error thrown out of `ComfyCloudClient` is one of
/// these cases, as is every failure of the Comfy Router surface — which carries its own,
/// spec-declared classification under `router(_:)` rather than being flattened into the cases
/// above.
public enum ComfyError: Error, Sendable {

    /// Authentication failed; the supplied credential was rejected by the server.
    case authInvalid

    /// Credentials were once valid but have expired.
    case authExpired

    /// The OAuth callback's `state` did not match the value from the originating authorization
    /// request — a possible CSRF or a crossed session. The callback was rejected without
    /// redeeming the code. Thrown by ``OAuthAuthorizationRequest/extractCode(fromCallback:)``.
    case authStateMismatch

    /// The OAuth authorization did not complete: the user cancelled or denied consent, or the
    /// callback carried no usable authorization code. Thrown by
    /// ``OAuthAuthorizationRequest/extractCode(fromCallback:)`` when the callback has no
    /// non-empty `code`.
    case authCancelled

    /// The token endpoint refused the authorization-code exchange (HTTP 400 on the
    /// `authorization_code` grant). This is always a failed *sign-in*, so it is never
    /// ``ComfyError/authExpired`` — there is no session to expire — and never
    /// ``ComfyError/network``, which would invite retrying a request that cannot
    /// succeed as sent.
    ///
    /// **Every** 400 on this grant arrives here, so `code` is what says which kind of
    /// refusal it was. Branch on it before choosing a recovery:
    ///
    /// - `"invalid_grant"` — the authorization *code* was refused: expired, already
    ///   redeemed, unknown, or not matching the `redirect_uri` or PKCE verifier it was
    ///   issued against. This is the re-authenticate case: no retry of the same code
    ///   can fix it, and starting sign-in again mints a fresh one.
    /// - `"invalid_request"`, `"invalid_client"`, `"unauthorized_client"`,
    ///   `"unsupported_grant_type"` — the *request* was malformed, or this client is
    ///   not configured for this grant. A fresh code cannot fix these, so re-presenting
    ///   the sign-in sheet on them loops forever; treat them as a request or
    ///   client-configuration bug — a malformed `code` or `codeVerifier` argument, or a
    ///   wrong `client_id` / `redirect_uri` in a custom ``OAuthClientConfig``.
    /// - `nil` — the body was not parseable as RFC 6749 §5.2, or carried no usable
    ///   code. The refusal is real but unattributable; a proxy or WAF answering in
    ///   front of the endpoint looks like this.
    ///
    /// `code` is the RFC 6749 §5.2 `error` value, sanitized then trimmed and
    /// lowercased, so it can be compared with `==`. `detail` is the optional
    /// `error_description`, or `nil` when it was absent or empty. Both are stripped of
    /// control characters and length-clamped, and scrubbed of the request's own
    /// secrets — `detail` unconditionally, `code` only for secrets of 8 characters or
    /// more, because an unanchored match on a shorter value would corrupt the one
    /// machine-readable field here (a `codeVerifier` of `"v"` would rewrite
    /// `invalid_grant` into `in<redacted>alid_grant`). Neither field is user-facing
    /// copy.
    case authCodeRejected(code: String?, detail: String?)

    /// A transport-level network failure not otherwise classified, carrying the underlying error.
    case network(underlying: Error)

    /// The device has no network connectivity.
    case offline

    /// The request did not complete within the SDK's timeout window.
    case timeout

    /// The server rejected the workflow with a structured reason.
    case serverRejected(reason: ServerRejectionReason)

    /// The server's content filter rejected the prompt or output.
    case contentFiltered

    /// The job started but failed during a specific phase, given as a transport-agnostic label.
    case jobFailed(phase: String)

    /// The server rate-limited the request, optionally indicating when to retry.
    case rateLimited(retryAfter: TimeInterval?)

    /// The job was cancelled cooperatively by the consumer task.
    case cancelled

    /// A Comfy Router model run failed; see `RouterError.errorType`.
    case router(RouterError)

    /// An error that escaped every other case, carrying the underlying error for debugging.
    case unknown(underlying: Error)
}

/// Typed reason for `ComfyError.serverRejected(reason:)`.
public enum ServerRejectionReason: Sendable {
    /// The server could not parse the workflow JSON.
    case malformedWorkflow

    /// The requested model is not available right now.
    case modelUnavailable

    /// The user has hit their plan's quota for this billing period.
    case quotaExceeded

    /// The account has no credits left (HTTP 402, or a partner node refusing
    /// mid-run with "Payment Required"). Distinct from `quotaExceeded`: a quota
    /// resets with the billing period, whereas this clears only by adding
    /// credits — so consumers should route the user to top up, not to wait.
    case insufficientCredits

    /// A server-side rejection that doesn't fit the other cases, carrying a stable machine identifier.
    case other(String)
}

extension ComfyError: CustomStringConvertible, CustomDebugStringConvertible {

    /// A description that is safe to log.
    ///
    /// Supplied because the default reflection is not. `ComfyError` carried only `Error, Sendable`,
    /// so `String(describing:)` and every `"\(error)"` interpolation fell to Swift's enum
    /// reflection — which prints each case's associated values verbatim, unbounded, with control
    /// characters passed through. Three payloads reach that renderer carrying server- or
    /// network-derived text:
    ///
    /// - ``ComfyError/network(underlying:)`` and ``ComfyError/unknown(underlying:)`` box a
    ///   `URLError` whose bridged `NSError` `userInfo` carries the failing URL including its query
    ///   string (`NSURLErrorFailingURLStringErrorKey`); reflection emits the whole
    ///   `Error Domain=… UserInfo={…}` string.
    /// - ``ComfyError/unknown(underlying:)`` also boxes `SubmitErrorBody`, whose `message` is the
    ///   raw string the submit endpoint sent.
    /// - ``ComfyError/serverRejected(reason:)`` carries `.other(_:)`, whose payload is the raw
    ///   `error` / `message` / `reason` field from the server's JSON.
    ///
    /// ``RouterError`` already solved this for itself; this brings the rest of the taxonomy to the
    /// same bar. Nothing should parse this string — it is a log rendering, not a wire format, and
    /// the full values remain readable on the associated values themselves.
    public var description: String {
        switch self {
        case .authInvalid:
            return "ComfyError.authInvalid"
        case .authExpired:
            return "ComfyError.authExpired"
        case .authStateMismatch:
            return "ComfyError.authStateMismatch"
        case .authCancelled:
            return "ComfyError.authCancelled"
        case let .authCodeRejected(code, detail):
            // Both are already scrubbed and clamped where they are built, in
            // `OAuthTokenEndpoint`. Routing them through `loggable` anyway keeps the guarantee a
            // property of the renderer rather than of one construction path.
            return "ComfyError.authCodeRejected(code: \(Self.loggable(code ?? "nil"))"
                + ", detail: \(Self.loggable(detail ?? "nil")))"
        case let .network(underlying):
            return "ComfyError.network(\(Self.loggable(underlying)))"
        case .offline:
            return "ComfyError.offline"
        case .timeout:
            return "ComfyError.timeout"
        case let .serverRejected(reason):
            return "ComfyError.serverRejected(reason: \(Self.rendered(reason)))"
        case .contentFiltered:
            return "ComfyError.contentFiltered"
        case let .jobFailed(phase):
            // `PhaseLabel.forNode` maps to a closed vocabulary and never passes node text
            // through, so this is safe to include; it still goes through `loggable` so a phase
            // built by some future path cannot reopen the hole.
            return "ComfyError.jobFailed(phase: \(Self.loggable(phase)))"
        case let .rateLimited(retryAfter):
            // NOT `Int(retryAfter)`. That is a trapping conversion on a response-controlled
            // value: `Retry-After: 9223372036854775807` stores `TimeInterval(Int.max)`, which as
            // a `Double` is exactly 2^63 — one past `Int.max` — and `Int(_:)` on it is a
            // precondition failure that terminates the process. Rendering the `Double` cannot
            // trap. See the same note on `RouterError.description`.
            guard let retryAfter else { return "ComfyError.rateLimited(retryAfter: nil)" }
            return "ComfyError.rateLimited(retryAfter: \(retryAfter)s)"
        case .cancelled:
            return "ComfyError.cancelled"
        case let .router(error):
            // DELEGATE. `RouterError.description` is already the sanitized rendering, and it
            // deliberately withholds the `Idempotency-Key` (workspace-scoped: anyone who can read
            // the log can spend it) and the server-echoed `input` values inside
            // `validationErrors`. Re-rendering its stored fields here would leak exactly those.
            return "ComfyError.router(\(error.description))"
        case let .unknown(underlying):
            return "ComfyError.unknown(\(Self.loggable(underlying)))"
        }
    }

    public var debugDescription: String { description }

    /// A boxed error, rendered with its concrete type named and its reflected text bounded.
    ///
    /// The type name is the debuggable half and is never caller or server text — it is a Swift
    /// type. Everything else the boxed error reflects is untrusted, so it is control-stripped and
    /// clamped: that is what bounds `SubmitErrorBody`'s raw server string, a `DecodingError`'s
    /// context, and any transport `NSError`, without discarding the prefix that makes the log line
    /// worth reading.
    private static func loggable(_ error: Error) -> String {
        "\(type(of: error)): \(loggable(reflected(error)))"
    }

    /// What is safe to reflect out of a boxed error.
    ///
    /// For a `URLSession` failure, `String(describing:)` is not — and **clamping it does not make
    /// it so**. The bridged `NSError`'s `userInfo` carries the failing URL, query string included
    /// (`NSErrorFailingURLStringKey` / `NSErrorFailingURLKey`), and the SDK's own WebSocket URL
    /// puts the API key or OAuth access token in that URL's `token` query item — see
    /// ``WebSocketSession/buildWebSocketURL(baseURL:credential:clientID:)``. A `receive()` failure
    /// on that task reaches ``ComfyError/network(underlying:)`` through `Transport.translate`, and
    /// the whole leaking string measures ~271 bytes: it fits the byte budget several times over,
    /// so a length bound alone would still print a live credential into a consumer's log. This
    /// repo's rule is that credentials stay out of logs and error messages, so the `userInfo` is
    /// not rendered at all.
    ///
    /// What survives is the part that is actually diagnostic and cannot carry a secret: the error
    /// domain, the `URLError.Code` raw value — which *is* the classification — and the failing
    /// URL's scheme, host and path, with the query, fragment and any userinfo dropped. When the
    /// failing URL is absent or unparseable the domain and code stand alone, which is the safe
    /// direction. Every other error type still reflects normally.
    private static func reflected(_ error: Error) -> String {
        let bridged = error as NSError
        guard bridged.domain == NSURLErrorDomain else { return String(describing: error) }
        let base = "\(NSURLErrorDomain) code=\(bridged.code)"
        guard let failing = bridged.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
              var components = URLComponents(url: failing, resolvingAgainstBaseURL: false) else {
            return base
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let redacted = components.string else { return base }
        return "\(base) url=\(redacted)"
    }

    /// One untrusted field, control-stripped and clamped to a UTF-8 byte budget.
    private static func loggable(_ value: String) -> String {
        LogSafeText.bounded(value)
    }

    /// ``ServerRejectionReason`` has no `CustomStringConvertible` of its own, so interpolating it
    /// would reflect `.other(_:)`'s raw server string verbatim. Rendered here instead.
    private static func rendered(_ reason: ServerRejectionReason) -> String {
        switch reason {
        case .malformedWorkflow:   return "malformedWorkflow"
        case .modelUnavailable:    return "modelUnavailable"
        case .quotaExceeded:       return "quotaExceeded"
        case .insufficientCredits: return "insufficientCredits"
        case let .other(message):  return "other(\(loggable(message)))"
        }
    }
}
