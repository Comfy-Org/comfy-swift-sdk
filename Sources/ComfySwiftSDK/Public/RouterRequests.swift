import Foundation

// MARK: - Request state

/// Where a queued Comfy Router request has reached.
///
/// The contract declares three values. A fourth the server may add later decodes as
/// ``unknown(_:)`` rather than failing, and — this is the part that matters — an unknown value
/// is **not terminal**: a poller that treated it as one would stop watching a request that is
/// still running, and report it as finished when nothing said so.
public enum RouterRequestState: Sendable, Equatable, Hashable {

    /// Accepted and waiting for a worker. ``RouterRequestStatus/queuePosition`` is the place
    /// in line when the server reported one.
    case inQueue

    /// A worker has it and the model is running.
    case inProgress

    /// The request reached a terminal outcome — which is **not** the same as "succeeded".
    /// A cancellation that took effect, a provider failure and a content refusal all read
    /// `COMPLETED` here, distinguished by ``RouterRequestStatus/errorType``.
    case completed

    /// A value this SDK version does not know, carried verbatim. Treated as *not terminal*:
    /// keep polling, and let the deadline or the caller decide when to stop.
    case unknown(String)

    /// The wire value of every known state, in the contract's declaration order.
    private static let wire: [(RouterRequestState, String)] = [
        (.inQueue, "IN_QUEUE"),
        (.inProgress, "IN_PROGRESS"),
        (.completed, "COMPLETED")
    ]

    /// Decode a wire value. Anything outside the closed set becomes ``unknown(_:)``.
    ///
    /// Matched case-sensitively against the contract's own upper-case spelling: the values are
    /// an enumeration rather than free text, so a differently-cased one is a server this SDK
    /// should report as unrecognised rather than quietly normalise into a terminal state.
    public init(rawValue: String) {
        for (state, value) in Self.wire where value == rawValue {
            self = state
            return
        }
        self = .unknown(rawValue)
    }

    /// The wire value this state is sent as.
    public var rawValue: String {
        if case .unknown(let raw) = self { return raw }
        return Self.wire.first { $0.0 == self }?.1 ?? "IN_QUEUE"
    }

    /// Whether the server has stopped working on this request.
    ///
    /// Only ``completed``. ``unknown(_:)`` is deliberately excluded — see the case's own note.
    public var isTerminal: Bool { self == .completed }
}

/// One reading of a queued request's status, as ``RouterRequestHandle/status()`` returns it.
public struct RouterRequestStatus: Sendable, Equatable {

    /// The request id the status was read for.
    public let requestId: String

    /// Where the request has reached.
    public let state: RouterRequestState

    /// Place in line while ``state`` is ``RouterRequestState/inQueue``, when the server
    /// reported one. `nil` otherwise, and `nil` is not "position zero".
    public let queuePosition: Int?

    /// The failure bucket a `COMPLETED` status reported, or `nil` when the request completed
    /// successfully or has not completed at all.
    ///
    /// This is the field that makes a terminal status readable: a cancellation that took
    /// effect, a provider failure and a content refusal are all `COMPLETED`, and this is what
    /// tells them apart. ``RouterRequestHandle/result()`` and
    /// ``RouterModels/subscribe(_:input:onQueueUpdate:timeout:idempotencyKey:)`` throw
    /// ``ComfyError/router(_:)`` carrying it rather than returning a result.
    public let errorType: RouterErrorType?

    /// The server's `Retry-After` hint for the next poll, in seconds, already capped at
    /// ``RouterRequestHandle/maximumRetryAfter``. `nil` when the response carried no usable
    /// hint.
    public let retryAfter: TimeInterval?

    public init(
        requestId: String,
        state: RouterRequestState,
        queuePosition: Int? = nil,
        errorType: RouterErrorType? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.requestId = requestId
        self.state = state
        self.queuePosition = queuePosition
        self.errorType = errorType
        self.retryAfter = retryAfter
    }
}

/// What a cancel request achieved.
///
/// Cancel is a *request*, not a guarantee: the model may finish before the cancellation is
/// acted on. Either outcome here is a successful call — neither throws — and the authority on
/// what actually happened is a subsequent ``RouterRequestHandle/status()``, where a
/// cancellation that took effect reads `COMPLETED` carrying an
/// ``RouterRequestStatus/errorType`` like every other terminal outcome.
public enum RouterCancelOutcome: Sendable, Equatable {

    /// The server accepted the cancellation request (`202`). It may still not take effect.
    case cancellationRequested

    /// The request had already finished, so there was nothing to cancel (`400`).
    case alreadyCompleted
}

// MARK: - Handle

/// A queued Comfy Router request, addressable for as long as the server keeps it.
///
/// Returned by ``RouterModels/submit(_:input:idempotencyKey:timeout:)``, and rebuildable from
/// its two ids alone with ``RouterModels/handle(_:requestId:)`` — after an app relaunch, say —
/// without a request being made.
///
/// ```swift
/// let handle = try await client.models.submit("bfl/flux-2-pro", input: ["prompt": "a cat"])
/// for try await event in handle.events() {
///     if case .queued(let position) = event { print("position \(position ?? -1)") }
/// }
/// let result = try await handle.result()
/// ```
///
/// ### The routes are composed, never taken from the response
///
/// The submit response carries `status_url`, `response_url` and `cancel_url`. This SDK does
/// not follow them. Every request it makes stamps the client's credential onto it, so a URL
/// read out of a response body is a place the credential could be sent to on the server's
/// say-so; the routes are built from the contract-pinned templates in `RouterConstants`
/// against the client's own `baseURL` instead, which is the same rule
/// ``RouterModels/run(_:input:idempotencyKey:timeout:)`` follows and the reason redirects are
/// refused on the run route.
public struct RouterRequestHandle: Sendable {

    /// Upper bound, in seconds, on a server `Retry-After` hint before it is slept on.
    ///
    /// The hint is server-controlled and beats the SDK's own schedule, which is exactly why it
    /// needs a ceiling: without one a single header could park a poll loop for the whole of a
    /// caller's budget in one sleep, and a caller watching a queue has no way to tell that from
    /// a hung SDK. A minute is far above any legitimate queue hint and far below any budget
    /// worth spending in one uninterruptible wait.
    public static let maximumRetryAfter: TimeInterval = 60

    /// The server's id for this request — the value to persist across an app relaunch and
    /// rebuild a handle from.
    public let requestId: String

    /// The canonical `{provider}/{model}` ID the request was submitted against, exactly as it
    /// was passed.
    public let model: String

    /// The place in line the submit response reported, when it reported one. A point-in-time
    /// reading from the moment of submit — ``status()`` is the current one.
    public let queuePosition: Int?

    /// The `Idempotency-Key` the submit call was sent under, whether minted by the SDK or
    /// supplied by the caller. `nil` on a handle rebuilt by
    /// ``RouterModels/handle(_:requestId:)``, which makes no request and so has no key.
    public let idempotencyKey: String?

    /// The already-validated, already-encoded model path. Held rather than re-parsed so a
    /// handle cannot address a different route than the submit that produced it.
    internal let path: RouterTransport.ModelPath

    /// ``requestId`` percent-encoded as one path segment.
    internal let encodedRequestId: String

    internal let transport: RouterTransport

    internal init(
        requestId: String,
        model: String,
        queuePosition: Int?,
        idempotencyKey: String?,
        path: RouterTransport.ModelPath,
        encodedRequestId: String,
        transport: RouterTransport
    ) {
        self.requestId = requestId
        self.model = model
        self.queuePosition = queuePosition
        self.idempotencyKey = idempotencyKey
        self.path = path
        self.encodedRequestId = encodedRequestId
        self.transport = transport
    }

    /// Reads the request's current status. One `GET`, no polling.
    ///
    /// - Parameter timeout: Bound on this one call. Defaults to
    ///   ``RouterModels/defaultRequestTimeout``.
    /// - Returns: The status as the server reported it, including any `Retry-After` hint
    ///   already capped at ``maximumRetryAfter``.
    /// - Throws: ``ComfyError``. A `COMPLETED` status carrying an `error_type` is **not** a
    ///   throw here — it is a status, and ``RouterRequestStatus/errorType`` carries it. Reading
    ///   a status is how a caller discovers a failure, so failing the read would leave nowhere
    ///   to discover it from.
    public func status(
        timeout: TimeInterval = RouterModels.defaultRequestTimeout
    ) async throws -> RouterRequestStatus {
        try RouterTransport.validateTimeout(timeout)
        return try await transport.requestStatus(
            path: path,
            requestId: requestId,
            encodedRequestId: encodedRequestId,
            deadline: ContinuousClock.now.advanced(by: .seconds(timeout))
        )
    }

    /// Waits for the request to finish and collects its output.
    ///
    /// Polls to completion and then fetches — the Swift spelling of the Python SDK's
    /// `handle.get()` and the TypeScript SDK's `handle.get()`. The polling is the same
    /// poll-authoritative, adaptively backed-off loop ``events(timeout:)`` exposes; this call
    /// just does not show it to you.
    ///
    /// An elapsed `timeout` here throws **without cancelling**: the queue is the server's, and
    /// a local clock running out says nothing about it. Only
    /// ``RouterModels/subscribe(_:input:onQueueUpdate:timeout:idempotencyKey:)`` — which owns
    /// the request it submitted — issues the best-effort cancel.
    ///
    /// - Parameter timeout: Wall-clock bound on the whole wait: the poll requests, their
    ///   re-sends, the pauses between them and the result fetch. **The first poll is always
    ///   made, so `0` reads "look once"** — and then throws ``ComfyError/timeout`` if that one
    ///   look was not terminal. Defaults to ``RouterModels/defaultTimeout``.
    /// - Returns: The same ``RouterRunResult`` the synchronous
    ///   ``RouterModels/run(_:input:idempotencyKey:timeout:)`` returns — the provider's own
    ///   native output, unenveloped.
    /// - Throws: ``ComfyError``.
    ///   - ``ComfyError/router(_:)`` carrying the reported bucket when the request completed
    ///     with a failure — a provider error, a content refusal, or a cancellation that took
    ///     effect. **A `200` is never handed back as success when the completion reported a
    ///     failure.**
    ///   - ``ComfyError/timeout`` when `timeout` elapses before the request completes.
    public func result(
        timeout: TimeInterval = RouterModels.defaultTimeout
    ) async throws -> RouterRunResult {
        try RouterTransport.validatePollTimeout(timeout)
        return try await transport.collectRequest(
            path: path,
            requestId: requestId,
            encodedRequestId: encodedRequestId,
            idempotencyKey: idempotencyKey,
            timeout: timeout,
            onEvent: nil
        )
    }

    /// Asks the server to cancel the request. One `PUT`.
    ///
    /// A request, not a guarantee — see ``RouterCancelOutcome``. Neither outcome throws; a
    /// cancellation that took effect reads back on ``status()`` as `COMPLETED` carrying an
    /// ``RouterRequestStatus/errorType``, like every other terminal outcome.
    ///
    /// - Parameter timeout: Bound on this one call. Defaults to
    ///   ``RouterModels/defaultRequestTimeout``.
    /// - Throws: ``ComfyError`` for a refusal that is neither of the two declared outcomes.
    @discardableResult
    public func cancel(
        timeout: TimeInterval = RouterModels.defaultRequestTimeout
    ) async throws -> RouterCancelOutcome {
        try RouterTransport.validateTimeout(timeout)
        return try await transport.cancelRequest(
            path: path,
            encodedRequestId: encodedRequestId,
            deadline: ContinuousClock.now.advanced(by: .seconds(timeout))
        )
    }

    /// Polls the request and yields an observation each time its progress changes.
    ///
    /// Poll-authoritative with adaptive backoff: the schedule starts short and lengthens, and a
    /// server `Retry-After` beats it outright — capped at ``maximumRetryAfter`` before it is
    /// slept on. The first observation is always yielded; after that, only a change of
    /// ``RouterRequestStatus/state`` or ``RouterRequestStatus/queuePosition`` is, so a stalled
    /// queue is quiet rather than repetitive.
    ///
    /// The stream finishes after yielding the terminal observation. It does **not** fetch the
    /// output — call ``result(timeout:)`` afterwards, or use
    /// ``RouterModels/subscribe(_:input:onQueueUpdate:timeout:idempotencyKey:)`` for the
    /// submit-poll-collect whole.
    ///
    /// ### A reported completion failure is yielded, not thrown
    ///
    /// A `COMPLETED` carrying an `error_type` arrives here as an ordinary observation with
    /// ``RouterRequestStatus/errorType`` set — the same decision the Python and TypeScript SDKs
    /// made, and for the same reason: this is a **view of the queue's progress**, and
    /// ``result(timeout:)`` is the call that collects. The stream still throws for things that
    /// are not the request's own outcome — a transport failure, an elapsed `timeout`, a
    /// cancelled task.
    ///
    /// Cancelling the consuming task stops the polling and throws ``ComfyError/cancelled`` into
    /// the stream. Nothing is cancelled server-side — call ``cancel(timeout:)`` for that, and
    /// note that an elapsed `timeout` here does **not** cancel either: the queue is the
    /// server's, and a local clock running out says nothing about it.
    ///
    /// - Parameter timeout: Wall-clock bound on the whole watch — the poll requests, their own
    ///   re-sends, the pauses between them — after which ``ComfyError/timeout`` is thrown into
    ///   the stream. **The first poll is always made, so `0` reads "look once".** Defaults to
    ///   ``RouterModels/defaultTimeout``.
    /// - Returns: A stream of ``RouterRequestStatus``, throwing ``ComfyError`` on failure — the
    ///   same idiom as ``ComfyCloudClient/events(for:)``.
    public func events(
        timeout: TimeInterval = RouterModels.defaultTimeout
    ) -> AsyncThrowingStream<RouterRequestStatus, Error> {
        AsyncThrowingStream { continuation in
            // Held so `onTermination` can tear the poller down: a consumer that breaks out of
            // its `for try await` early must not leave a poll loop running against the server.
            let task = Task {
                do {
                    try RouterTransport.validatePollTimeout(timeout)
                    try await transport.watch(
                        path: path,
                        requestId: requestId,
                        encodedRequestId: encodedRequestId,
                        timeout: timeout,
                        onEvent: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
