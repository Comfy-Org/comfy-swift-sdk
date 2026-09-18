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
    ///
    /// Always present on a result from ``RouterModels/run(_:input:idempotencyKey:timeout:)`` or
    /// ``RouterModels/subscribe(_:input:onQueueUpdate:timeout:idempotencyKey:)``, both of which
    /// make the submit themselves. `nil` only on a result collected through a
    /// ``RouterRequestHandle`` that ``RouterModels/handle(_:requestId:)`` rebuilt from ids
    /// alone: that handle never made a submit, so there is no key it could report — and an
    /// invented one would be worse than none, because the documented recovery flow is to
    /// *re-send* this value.
    public let idempotencyKey: String?

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

extension RouterRunResult: CustomStringConvertible, CustomDebugStringConvertible {

    /// A description that is safe to log.
    ///
    /// The same reasoning as ``RouterError``'s, on the path a caller is *more* likely to log:
    /// default reflection would print ``idempotencyKey`` in full — a key is scoped to the
    /// workspace rather than to the user, so anyone who can read the log can spend it — and,
    /// alongside it, the entire ``data`` blob, which for an image model is megabytes of base64
    /// in a log line.
    ///
    /// Both remain readable as properties; persisting the key is the documented way to collect
    /// a run later. They are only out of the default rendering, which is where they escape by
    /// accident rather than on purpose.
    public var description: String {
        var parts = ["RouterRunResult(bytes: \(data.count)"]
        if let requestId { parts.append("requestId: \(requestId)") }
        if replayed { parts.append("replayed") }
        return parts.joined(separator: ", ") + ")"
    }

    public var debugDescription: String { description }
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

    /// The default wall-clock bound on ONE queued-delivery round trip — a submit, a status
    /// read or a cancel: **60 seconds**.
    ///
    /// Those three calls and no others: ``submit(_:input:idempotencyKey:timeout:)``,
    /// ``RouterRequestHandle/status(timeout:)`` and ``RouterRequestHandle/cancel(timeout:)``.
    ///
    /// Much shorter than ``defaultTimeout``, because none of them waits on a model. Each is a
    /// single fast round trip to Router's own queue, and the long wait that used to be inside
    /// the request is now the caller's own polling. The calls that *do* wait for a model —
    /// ``subscribe(_:input:onQueueUpdate:timeout:idempotencyKey:)``,
    /// ``RouterRequestHandle/result(timeout:)`` and ``RouterRequestHandle/events(timeout:)``,
    /// each of which polls to completion before it collects — default to ``defaultTimeout``
    /// instead.
    public static let defaultRequestTimeout: TimeInterval = 60

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
    /// **Reproduce the whole call, not just the key.** A key identifies a request, and the
    /// contract refuses a reused one when "the method, the path and query, or the body differ".
    /// `modelProvider`, `strictMode` and `fallbackProvider` are sent as query parameters, so
    /// they are part of that identity exactly as `input` is: a collect that re-sends the key
    /// without reproducing all three is a *different* request under the same key and is refused
    /// `409` with ``RouterErrorType/invalidInput``, with the key consumed and the possibly
    /// charged generation left uncollectable. Persist them alongside the key.
    ///
    /// - Parameters:
    ///   - model: The canonical model ID, exactly two `/`-separated segments —
    ///     `"bfl/flux-2-pro"`. The `{provider}/{model}/{variant}` form is not addressable on
    ///     this route; pass the two-segment ID the catalog lists.
    ///   - input: The model's own native JSON input. Must be JSON-serialisable — see
    ///     `JSONSerialization.isValidJSONObject(_:)`.
    ///   - modelProvider: An alternate provider to serve this model, sent as the
    ///     `model_provider` query parameter — `"fal"`, say. `nil` (the default) omits the
    ///     parameter entirely and is byte-for-byte the request this route has always made, which
    ///     serves the model on its own default provider. A value naming a real provider that
    ///     does not serve this model is refused ``ComfyError/router(_:)`` with
    ///     ``RouterErrorType/modelNotFound``; a value that is not a registered provider at all is
    ///     refused with ``RouterErrorType/invalidInput``. An empty string, or one longer than the
    ///     contract's 64-character provider maximum, is refused here before anything is sent —
    ///     `""` would otherwise buy a guaranteed `invalid_input` rather than the
    ///     default-provider behaviour it reads as.
    ///   - strictMode: How the body and the response are shaped when ``modelProvider`` selects
    ///     an alternate provider, sent as the `strict_mode` query parameter. `nil` (the default)
    ///     omits it and lets the server apply its own default, which is `false`. `false` has
    ///     Router translate between this model's native contract and the alternate provider's
    ///     real schema in both directions; `true` sends and returns the alternate provider's own
    ///     raw shape unchanged, so `input` must already be that provider's schema. Meaningful
    ///     only together with ``modelProvider``, and **not sent at all without it**: with no
    ///     alternate provider selected there is no translation to switch off, and a parameter
    ///     that does nothing would still change the request's identity under its
    ///     `Idempotency-Key` (see below).
    ///   - fallbackProvider: Whether Router retries this call against the model's other
    ///     registered provider when the first attempt fails for a reason attributable to Router
    ///     or to the provider tried — never to the request itself. Sent as the
    ///     `fallback_provider` query parameter, with or without ``modelProvider``: the retry is
    ///     defined against the model's other registered provider, so opting out of it is
    ///     meaningful on a default-provider run too. `nil` (the default) omits it and leaves
    ///     fallback on, as does any value other than `"false"`; pass `"false"` to opt out, so a
    ///     failure is refused rather than retried. Note that the match is on the exact literal
    ///     `"false"` — `"False"`, `"0"` and `"no"` all leave fallback ON. Bounded and rejected
    ///     empty on the same terms as ``modelProvider``.
    ///   - idempotencyKey: The key to run under. Defaults to a freshly minted lowercase UUID,
    ///     minted once per call and reused across every internal re-send. Keys are scoped to
    ///     the **workspace** your credential carries, not to you, so supply one that is unique
    ///     across that whole workspace. A supplied key must be 1–255 printable ASCII
    ///     characters with no spaces — the shape a UUID already has — and is rejected before
    ///     anything is sent otherwise.
    ///   - timeout: Bound on the whole call, including any collect waits and any re-send after
    ///     a credential refresh: an attempt is given what is *left* of it, not a fresh copy.
    ///     Measured on a monotonic clock, so a system clock adjustment mid-run neither extends
    ///     nor truncates it. It is a hard stop rather than an idle timeout — when it elapses
    ///     the in-flight request is cancelled and ``ComfyError/timeout`` is thrown, even if the
    ///     server is still answering, so a run that trickles bytes forever cannot outlive it.
    ///     The one thing it cannot pre-empt is an OAuth `refreshProvider` of your own that
    ///     never returns: a refresh is shared between concurrent callers, so one call giving
    ///     up does not end it. Must be between 1 second and 24 hours — a sub-second budget is
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
    ///     `idempotencyKey` is outside the shape above,
    ///     `.other("invalid_model_provider")` / `.other("invalid_fallback_provider")` when the
    ///     matching parameter is empty or over the contract's 64-character provider maximum,
    ///     `.other("invalid_timeout")` when
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
    ///     than treating it as a failure. That is true of the `timeout` above in particular:
    ///     hanging up on the socket is not a server-side cancel, Router has no endpoint for
    ///     one, and the generation the key names may keep running and be charged. That
    ///     recovery needs a key you supplied and kept: a defaulted key is minted inside this
    ///     call and is not carried on the thrown error, so there is nothing to re-send it
    ///     under. See *Collecting after the app was suspended*
    ///     above — pass your own `idempotencyKey:` for any run you intend to be recoverable.
    public func run(
        _ model: String,
        input: [String: Any],
        modelProvider: String? = nil,
        strictMode: Bool? = nil,
        fallbackProvider: String? = nil,
        idempotencyKey: String? = nil,
        timeout: TimeInterval = RouterModels.defaultTimeout
    ) async throws -> RouterRunResult {
        // Every one of these throws before anything is sent. The ones that do not depend on
        // the key run first, so a call that never reaches the wire does not burn a key from
        // the workspace keyspace on its way to being refused.
        let path = try RouterTransport.parseModelId(model)
        try RouterTransport.validateTimeout(timeout)
        let body = try RouterTransport.serializeInput(input)

        // Built here from the typed parameters and sent only for the ones the caller set: an
        // omitted parameter contributes no query item, so a call that names none posts to the
        // exact URL this route has always used. Built BEFORE the key for the reason above —
        // a `modelProvider` this SDK refuses should not have cost a key on its way out.
        let query = try RouterTransport.runQuery(
            modelProvider: modelProvider,
            strictMode: strictMode,
            fallbackProvider: fallbackProvider
        )

        // Resolved once, here, outside the collect loop — re-minting per attempt would make
        // every re-send a NEW logical call, which is exactly what the key exists to prevent.
        // A supplied key is checked here rather than at the wire, where an uncarriable one
        // becomes a blank header the server reads as "no key at all".
        let key = try RouterTransport.validatedIdempotencyKey(idempotencyKey)

        return try await transport.run(
            path: path,
            body: body,
            query: query,
            idempotencyKey: key,
            timeout: timeout
        )
    }
    // MARK: - Queued delivery

    /// Submits a Comfy Router model run to the queue and returns immediately with a handle.
    ///
    /// The queued counterpart to ``run(_:input:idempotencyKey:timeout:)``. One `POST` enqueues
    /// the run and answers with its id; nothing here waits for the model. Watch the returned
    /// ``RouterRequestHandle`` — ``RouterRequestHandle/events(timeout:)`` for progress,
    /// ``RouterRequestHandle/result(timeout:)`` for the output — or persist
    /// ``RouterRequestHandle/requestId`` and rebuild the handle later with
    /// ``handle(_:requestId:)``. For submit-poll-collect in one call, use
    /// ``subscribe(_:input:onQueueUpdate:timeout:idempotencyKey:)``.
    ///
    /// Queued delivery is gated **server-side**: outside the preview, Router answers `403
    /// not_enabled` and this throws ``ComfyError/router(_:)`` with
    /// ``RouterErrorType/notEnabled``. There is no client-side flag to set.
    ///
    /// ### The id is the recoverable thing here, not the key
    ///
    /// On the run route the `Idempotency-Key` is what collects a generation whose connection did
    /// not survive. On the queue route the *request id* is: it is server-assigned, it outlives
    /// the connection by construction, and ``handle(_:requestId:)`` rebuilds a working handle
    /// from it with no request made. Persist it as soon as `submit` returns — on iOS,
    /// before doing anything that could suspend the app.
    ///
    /// - Parameters:
    ///   - model: The canonical `{provider}/{model}` model ID — same rules as `run`.
    ///   - input: The model's own native JSON input. Must be JSON-serialisable.
    ///   - idempotencyKey: The key this submit is sent under. Defaults to a **freshly minted**
    ///     lowercase UUID — one per `submit` call, reused by every re-send inside that call, so
    ///     a `409 concurrency_limit_exceeded` collects the enqueue already in flight rather than
    ///     queueing a second run. Supply your own to make the submit itself replayable.
    ///   - timeout: Bound on this one enqueue call. Defaults to ``defaultRequestTimeout``, which
    ///     is deliberately short: this call does not wait for the model.
    /// - Returns: A ``RouterRequestHandle`` for the queued request.
    /// - Throws: ``ComfyError``, with the same pre-flight rejections `run` makes — a malformed
    ///   model ID, an uncarriable `idempotencyKey`, an out-of-range `timeout`, a bad
    ///   `routerBaseURL` — all thrown before anything is sent.
    public func submit(
        _ model: String,
        input: [String: Any],
        idempotencyKey: String? = nil,
        timeout: TimeInterval = RouterModels.defaultRequestTimeout
    ) async throws -> RouterRequestHandle {
        let path = try RouterTransport.parseModelId(model)
        try RouterTransport.validateTimeout(timeout)
        let body = try RouterTransport.serializeInput(input)
        let key = try RouterTransport.validatedIdempotencyKey(idempotencyKey)

        let acknowledgement = try await transport.submitRequest(
            path: path,
            body: body,
            idempotencyKey: key,
            deadline: ContinuousClock.now.advanced(by: .seconds(timeout))
        )

        return RouterRequestHandle(
            requestId: acknowledgement.requestId,
            model: model,
            queuePosition: acknowledgement.queuePosition,
            idempotencyKey: key,
            path: path,
            encodedRequestId: acknowledgement.encodedRequestId,
            transport: transport
        )
    }

    /// Submits, waits, and returns the output — queued delivery in one call.
    ///
    /// Submit plus poll plus collect, returning the same ``RouterRunResult``
    /// ``run(_:input:idempotencyKey:timeout:)`` returns. Reach for this when you want queued
    /// delivery's robustness without managing a handle; reach for
    /// ``submit(_:input:idempotencyKey:timeout:)`` when the id has to outlive the call.
    ///
    /// Polling is **poll-authoritative** and adaptively backed off: the status route decides
    /// when the request is done, the pause between polls starts short and lengthens, and a
    /// server `Retry-After` beats that schedule outright — capped at
    /// ``RouterRequestHandle/maximumRetryAfter`` before it is slept on.
    ///
    /// ### Giving up cancels, best-effort
    ///
    /// When `timeout` elapses, or the calling task is cancelled, the SDK issues **one** cancel
    /// for the queued request — sent once, bounded short — and then throws ``ComfyError/timeout``
    /// or ``ComfyError/cancelled``. The cancel is cleanup: its own failure never replaces the
    /// error you are being given, and it is a request rather than a guarantee, so the request
    /// may still complete and be charged. Nothing else is cancelled for you — a failure that is
    /// already terminal server-side is left alone.
    ///
    /// - Parameters:
    ///   - model: The canonical `{provider}/{model}` model ID.
    ///   - input: The model's own native JSON input.
    ///   - onQueueUpdate: Called with the submit acknowledgement and then with each change in
    ///     the request's observed state or queue position — the Swift spelling of the Python
    ///     SDK's `on_queue_update` and the TypeScript SDK's `onQueueUpdate`. Consecutive
    ///     identical observations are collapsed, so this does not fire once per poll. Called
    ///     from the SDK's own task while it holds the poll loop; keep it cheap and do not block
    ///     in it.
    ///   - timeout: Wall-clock bound on the **whole** wait — the submit, the poll requests, their
    ///     re-sends, the pauses between them and the result fetch. Not an idle timeout, and
    ///     measured on a monotonic clock. Defaults to ``defaultTimeout``.
    ///   - idempotencyKey: The key the submit is sent under. Defaults to a freshly minted
    ///     lowercase UUID.
    /// - Returns: The model's output.
    /// - Throws: ``ComfyError``. ``ComfyError/router(_:)`` carries the reported bucket when the
    ///   request completed with a failure — including a cancellation that took effect, which the
    ///   contract reports as a completion like any other.
    public func subscribe(
        _ model: String,
        input: [String: Any],
        onQueueUpdate: (@Sendable (RouterRequestStatus) -> Void)? = nil,
        timeout: TimeInterval = RouterModels.defaultTimeout,
        idempotencyKey: String? = nil
    ) async throws -> RouterRunResult {
        let path = try RouterTransport.parseModelId(model)
        try RouterTransport.validateTimeout(timeout)
        let body = try RouterTransport.serializeInput(input)
        let key = try RouterTransport.validatedIdempotencyKey(idempotencyKey)

        return try await transport.subscribe(
            path: path,
            body: body,
            idempotencyKey: key,
            timeout: timeout,
            onQueueUpdate: onQueueUpdate
        )
    }

    /// Rebuilds a handle for a request that is already queued. **No request is made.**
    ///
    /// The relaunch path: persist ``RouterRequestHandle/requestId`` alongside the model ID when
    /// you submit, and this reconstructs a working handle from the two — on a new client, in a
    /// new process, hours later — without a round trip.
    ///
    /// Both ids are validated locally, so a handle either addresses a well-formed route or
    /// throws here rather than composing a request from whatever was in your database.
    ///
    /// - Parameters:
    ///   - model: The canonical `{provider}/{model}` model ID the request was submitted against.
    ///   - requestId: The server's request id. Must be one printable path segment of at most 256
    ///     characters.
    /// - Returns: A ``RouterRequestHandle``. Its ``RouterRequestHandle/idempotencyKey`` and
    ///   ``RouterRequestHandle/queuePosition`` are `nil` — neither is knowable without the
    ///   submit that produced them; ``RouterRequestHandle/status()`` reads the current position.
    /// - Throws: ``ComfyError/serverRejected(reason:)`` carrying
    ///   ``ServerRejectionReason/other(_:)`` — `"invalid_model_id"` for a malformed model ID,
    ///   `"invalid_request_id"` for a request id that is not one printable path segment.
    public func handle(_ model: String, requestId: String) throws -> RouterRequestHandle {
        let path = try RouterTransport.parseModelId(model)
        let encodedRequestId = try RouterTransport.validatedRequestId(requestId)

        return RouterRequestHandle(
            requestId: requestId,
            model: model,
            queuePosition: nil,
            idempotencyKey: nil,
            path: path,
            encodedRequestId: encodedRequestId,
            transport: transport
        )
    }
}
