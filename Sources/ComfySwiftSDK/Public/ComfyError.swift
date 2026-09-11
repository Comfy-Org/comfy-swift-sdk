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
