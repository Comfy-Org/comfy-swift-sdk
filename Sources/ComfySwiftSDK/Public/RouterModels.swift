import Foundation

/// One finished Comfy Router model run.
///
/// Router forwards the partner model's own native JSON output unchanged, so there is no
/// Comfy-shaped envelope to unwrap: ``data`` is those bytes exactly as they arrived, and
/// ``output`` is the same document as a navigable value. Read whichever suits — they never
/// disagree, because ``output`` is parsed from ``data``.
///
/// ```swift
/// let result = try await client.models.run("bfl/flux-2-pro", input: ["prompt": "a cat"])
/// let url = result.output["images"][0]["url"].stringValue
/// ```
public struct RouterRunResult: Sendable {

    /// The model's native JSON output, byte-for-byte as Router returned it.
    ///
    /// Carried verbatim rather than re-encoded, so a caller that needs an exact copy — to
    /// cache it, hash it, or hand it to a decoder of its own — gets the server's bytes and not
    /// this SDK's round-trip of them. Populated even when the body was not JSON at all, in
    /// which case ``output`` is ``RouterJSON/null``.
    public let data: Data

    /// A read-only view of ``data``, for reading a field without declaring a `Decodable` type.
    ///
    /// Both subscripts answer ``RouterJSON/null`` on a miss, so a deep read never traps:
    /// `result.output["images"][0]["url"].stringValue` is `nil` — not a crash — on a response
    /// with no images.
    ///
    /// ``RouterJSON/null`` when the body was empty or was not JSON; ``data`` still carries it.
    public let output: RouterJSON

    /// The `X-Comfy-Request-Id` of the call — the id to quote in a support request, and the
    /// same value written into the call's usage and audit events. `nil` when the response
    /// carried no such header.
    public let requestId: String?

    /// The `Idempotency-Key` this call was sent under, whether minted by the SDK or supplied
    /// by the caller.
    ///
    /// Worth persisting *before* awaiting the run on iOS: it is the only handle that collects
    /// a generation whose connection did not survive — see the discussion on
    /// ``RouterModels/run(_:input:idempotencyKey:timeout:)``.
    public let idempotencyKey: String

    /// Whether the response was served from this key's 24-hour record rather than by running
    /// the model again.
    ///
    /// A replay is **not billed a second time**. `false` on a first call and on every response
    /// Router produced by actually dispatching the provider.
    public let replayed: Bool

    /// Decodes ``data`` into a `Decodable` type of your own.
    ///
    /// - Parameters:
    ///   - type: The type to decode the model's output into.
    ///   - decoder: The decoder to use. Pass your own to configure key or date strategies;
    ///     the default is a stock `JSONDecoder`.
    /// - Throws: Whatever `decoder` throws — a `DecodingError` when the model's output does
    ///   not match `type`. Not translated into ``ComfyError``: the output shape is the partner
    ///   model's, so a mismatch is between the caller's type and the provider's document, and
    ///   `DecodingError`'s own diagnosis names the offending key.
    public func decode<T: Decodable>(
        _ type: T.Type,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        try decoder.decode(type, from: data)
    }
}

/// The Comfy Router surface of a ``ComfyCloudClient`` — reach it as `client.models`.
///
/// Router runs a partner model by its canonical `{provider}/{model}` ID over a single
/// synchronous request: the body is the model's own native JSON input, the response is its own
/// native JSON output, and nothing in between is re-enveloped by Comfy.
///
/// ```swift
/// let client = ComfyCloudClient(apiKey: key)
/// let result = try await client.models.run(
///     "bfl/flux-2-pro",
///     input: ["prompt": "a cat", "width": 1024]
/// )
/// print(result.output["images"][0]["url"].stringValue ?? "")
/// ```
///
/// This is a different surface from ``ComfyCloudClient/submit(_:)``, which queues a ComfyUI
/// workflow graph on Comfy Cloud and streams its lifecycle. They share a credential and
/// nothing else — different host, different contract, different failure taxonomy
/// (``ComfyError/router(_:)`` rather than ``ComfyError/serverRejected(reason:)``).
public struct RouterModels: Sendable {

    /// The default wall-clock bound on one ``run(_:input:idempotencyKey:timeout:)`` call:
    /// **660 seconds**.
    ///
    /// Deliberately longer than Router's own 10-minute server-side deadline. The extra minute
    /// is headroom: with a shorter client bound the SDK would give up *first*, turning the
    /// `504 deadline_exceeded` the server was about to send — which the collect loop handles —
    /// into a client-side timeout whose outcome is unknown.
    public static let defaultTimeout: TimeInterval = 660

    /// The Router host the SDK posts to by default, `https://api.comfy.org`.
    ///
    /// Re-exported from the internal constant that
    /// `Scripts/contract/check_router_contract.py` pins to the vendored spec's `servers[0]`,
    /// so this value cannot drift from the contract without failing CI.
    public static let defaultBaseURL: URL = RouterConstants.defaultBaseURL

    /// The Router host this client's model runs are addressed to.
    ///
    /// ``defaultBaseURL`` unless the client was built with a `routerBaseURL:` override.
    public let baseURL: URL

    private let transport: RouterTransport

    internal init(baseURL: URL, transport: RouterTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// Runs a Comfy Router model and returns its output.
    ///
    /// One `POST` is held open until the model answers — there is no queue to poll and no
    /// handle to reattach to. The call is made under an `Idempotency-Key`, which is what makes
    /// re-running it safe: **a key is charged at most once**, and a re-run under the same key
    /// is answered from that key's record (``RouterRunResult/replayed`` is then `true`) or,
    /// while the original generation is still in flight, collects that generation rather than
    /// starting a second one.
    ///
    /// The SDK re-sends under that key by itself for the two answers the contract says a
    /// re-send collects — a `409 concurrency_limit_exceeded` and a `504 deadline_exceeded` —
    /// each only when the response carried a `Retry-After` *and* what is left of `timeout`
    /// covers both that wait and a short budget for the re-send itself to answer in. Those are
    /// the only two the contract declares that header on. When the wait would fit but leave too
    /// little behind it, the ``ComfyError/router(_:)`` already in hand is thrown instead — it
    /// names the request id, the `Retry-After` and the key, and so tells you the generation is
    /// still collectable, which the bare ``ComfyError/timeout`` of a doomed re-send would not.
    /// It never re-sends after a transport failure or a client-side timeout: that outcome is
    /// unknown, and re-sending blind is a decision only the caller can make.
    ///
    /// ### Collecting after the app was suspended
    ///
    /// The SDK's session is a foreground default session, which iOS does not keep alive across
    /// suspension. A run that was in flight when the app suspended is not resumed for you.
    /// Persist the key **before** you await — pass your own `idempotencyKey:` so you have it up
    /// front — and on relaunch call `run` again with that same key to collect the generation.
    /// Wrapping the call in `beginBackgroundTask(expirationHandler:)` buys the OS grace period
    /// for short runs; it is not a substitute for persisting the key.
    ///
    /// - Parameters:
    ///   - model: The canonical model ID, exactly two `/`-separated segments —
    ///     `"bfl/flux-2-pro"`. The `{provider}/{model}/{variant}` form is not addressable on
    ///     this route; pass the two-segment ID the catalog lists.
    ///   - input: The model's own native JSON input. Must be JSON-serialisable — see
    ///     `JSONSerialization.isValidJSONObject(_:)`.
    ///   - idempotencyKey: The key to run under. Defaults to a freshly minted lowercase UUID,
    ///     minted once per call and reused across every internal re-send. Keys are scoped to
    ///     the **workspace** your credential carries, not to you, so supply one that is unique
    ///     across that whole workspace. A supplied key must be 1–255 printable ASCII
    ///     characters with no spaces — the shape a UUID already has — and is rejected before
    ///     anything is sent otherwise.
    ///   - timeout: Bound on the whole call, including any collect waits and any re-send after
    ///     a credential refresh: an attempt is given what is *left* of it, not a fresh copy.
    ///     Measured on a monotonic clock, so a system clock adjustment mid-run neither extends
    ///     nor truncates it. Must be between 1 second and 24 hours — a sub-second budget is
    ///     refused rather than spent on one request too short to answer in. Defaults to
    ///     ``defaultTimeout``.
    /// - Returns: A ``RouterRunResult`` carrying the model's output, the request id, the key
    ///   the call ran under, and whether the answer was replayed.
    /// - Throws: ``ComfyError``.
    ///   - ``ComfyError/router(_:)`` for every Router-level refusal; branch on
    ///     ``RouterError/errorType``.
    ///   - ``ComfyError/serverRejected(reason:)`` with `.other("invalid_model_id")` (or
    ///     `.other("invalid_model_id_variant_unsupported")` for a three-segment ID) when
    ///     `model` is malformed, `.other("invalid_idempotency_key")` when a supplied
    ///     `idempotencyKey` is outside the shape above, `.other("invalid_timeout")` when
    ///     `timeout` is not finite or falls outside 1 second…24 hours, and
    ///     `.other("invalid_router_base_url")` when the client's `routerBaseURL` is not an
    ///     `https` URL with a host, no userinfo, and no query or fragment — all thrown before
    ///     any request is sent.
    ///   - ``ComfyError/unknown(underlying:)`` when `input` is not JSON-serialisable.
    ///   - ``ComfyError/authInvalid`` / ``ComfyError/authExpired`` when the credential is
    ///     refused (an OAuth client refreshes once and retries under the same key first).
    ///   - ``ComfyError/offline``, ``ComfyError/timeout``, ``ComfyError/network(underlying:)``
    ///     on transport failure, and ``ComfyError/cancelled`` when the calling task is
    ///     cancelled. For all four the run's outcome is **unknown** — it may have completed and
    ///     been charged — so collect it by calling again with the same `idempotencyKey:` rather
    ///     than treating it as a failure. That recovery needs a key you supplied and kept: a
    ///     defaulted key is minted inside this call and is not carried on the thrown error, so
    ///     there is nothing to re-send it under. See *Collecting after the app was suspended*
    ///     above — pass your own `idempotencyKey:` for any run you intend to be recoverable.
    public func run(
        _ model: String,
        input: [String: Any],
        idempotencyKey: String? = nil,
        timeout: TimeInterval = RouterModels.defaultTimeout
    ) async throws -> RouterRunResult {
        // Every one of these throws before anything is sent. The ones that do not depend on
        // the key run first, so a call that never reaches the wire does not burn a key from
        // the workspace keyspace on its way to being refused.
        let path = try RouterTransport.parseModelId(model)
        try RouterTransport.validateTimeout(timeout)
        let body = try RouterTransport.serializeInput(input)

        // Resolved once, here, outside the collect loop — re-minting per attempt would make
        // every re-send a NEW logical call, which is exactly what the key exists to prevent.
        // A supplied key is checked here rather than at the wire, where an uncarriable one
        // becomes a blank header the server reads as "no key at all".
        let key = try RouterTransport.validatedIdempotencyKey(idempotencyKey)

        return try await transport.run(
            path: path,
            body: body,
            idempotencyKey: key,
            timeout: timeout
        )
    }
}
