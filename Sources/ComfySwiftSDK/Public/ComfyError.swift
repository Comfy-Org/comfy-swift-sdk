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
    ///   the sign-in sheet on them loops forever; treat them as a client/configuration
    ///   bug, typically a wrong `client_id` or `redirect_uri` in a custom
    ///   ``OAuthClientConfig``.
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
