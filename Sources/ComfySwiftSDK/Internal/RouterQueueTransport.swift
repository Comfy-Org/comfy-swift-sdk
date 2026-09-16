import Foundation

/// The transport behind Comfy Router's **queued** delivery mode — `submit`, `subscribe`,
/// `handle`, and everything ``RouterRequestHandle`` can do.
///
/// An extension on ``RouterTransport`` rather than a second transport, deliberately. The
/// queue routes are the same host, the same credential, the same `Idempotency-Key` semantics
/// and the same error taxonomy as the synchronous run route; a separate type would fork the
/// base-URL validation, the redirect refusal, the 401 refresh and the wall-clock deadline
/// four ways at once. What is genuinely different — and is all that lives here — is that the
/// queue is *polled* rather than held open.
extension RouterTransport {

    // MARK: - Request id

    /// Stable machine identifier reported for a request id that cannot be a path segment.
    internal static let invalidRequestIdReason = "invalid_request_id"

    /// Upper bound, in Unicode scalars, on a request id.
    ///
    /// The contract's ids are UUIDs, so this is generous by two orders of magnitude. It is a
    /// bound rather than an exact shape for the same reason ``parseModelId(_:)`` does not
    /// enforce the model charset: an id whose *format* changes upstream must keep working,
    /// while an unbounded one is a request nobody meant to send — reaching the wire with the
    /// credential attached.
    internal static let requestIdMaxLength = 256

    /// The request id percent-encoded as ONE path segment, or a throw.
    ///
    /// Applied to a caller's id *and* to the one the server returns from submit. Validating the
    /// server's looks redundant and is not: the id is interpolated straight into the URL of
    /// every later status, result and cancel call, each of which carries the credential, so a
    /// `../` or a query character arriving in a response body would let the server re-point
    /// those calls at a route nobody asked for. `.` and `..` are refused rather than encoded,
    /// exactly as the model-ID segments are.
    ///
    /// - Throws: ``ComfyError/serverRejected(reason:)`` carrying
    ///   ``ServerRejectionReason/other(_:)`` with ``invalidRequestIdReason``.
    internal static func validatedRequestId(_ requestId: String) throws -> String {
        let scalars = requestId.unicodeScalars
        guard !scalars.isEmpty,
              scalars.count <= requestIdMaxLength,
              // Printable ASCII with no space, the same rule ``validatedIdempotencyKey(_:)``
              // applies — less the separator, which would re-shape the route.
              scalars.allSatisfy({ (0x21...0x7E).contains($0.value) && $0 != "/" }),
              requestId != ".", requestId != "..",
              let escaped = requestId.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed),
              !escaped.isEmpty
        else {
            SDKLog.routerRejectedBeforeSend(reason: invalidRequestIdReason)
            throw ComfyError.serverRejected(reason: .other(invalidRequestIdReason))
        }
        return escaped
    }

    // MARK: - Poll schedule

    /// The first pause between status polls, in seconds.
    ///
    /// Short, because the interesting case is a model that finishes in a second or two and a
    /// caller that should not wait a whole extra schedule tick to be told so.
    internal static let pollInitialDelay: TimeInterval = 0.5

    /// What each pause is multiplied by for the next one.
    internal static let pollBackoffFactor: Double = 1.5

    /// The longest pause the schedule will grow to, in seconds. A server that wants longer says
    /// so in `Retry-After`, which beats the schedule outright.
    internal static let pollMaximumDelay: TimeInterval = 10

    /// The bound on the best-effort cancel a timed-out or cancelled `subscribe` issues, in
    /// seconds.
    ///
    /// Short and deliberately so: the caller is already on their way out with a `.timeout` or a
    /// `.cancelled`, and this call exists to stop a generation being billed for, not to be
    /// waited on. It is also why it sends **once** — a retry loop here would turn giving up into
    /// a longer wait than not giving up.
    internal static let bestEffortCancelTimeout: TimeInterval = 5

    // MARK: - Submit

    /// What one accepted submit told us.
    internal struct RouterSubmitAcknowledgement: Sendable {
        /// The server's id, verbatim, as the caller should persist it.
        let requestId: String
        /// ``requestId`` percent-encoded as one path segment.
        let encodedRequestId: String
        /// The place in line the server reported, when it reported one.
        let queuePosition: Int?
        /// The state the server reported — `IN_QUEUE` on a conforming `201`.
        let state: RouterRequestState
    }

    /// `POST …/requests` — enqueues one run and returns its id.
    ///
    /// The same `Idempotency-Key` discipline as the run route: one key per `submit` call, reused
    /// by every re-send *inside* that call, so a `409 concurrency_limit_exceeded` collects the
    /// enqueue that is already in flight rather than queueing a second one.
    internal func submitRequest(
        path: ModelPath,
        body: Data,
        idempotencyKey: String,
        deadline: ContinuousClock.Instant
    ) async throws -> RouterSubmitAcknowledgement {
        let url = try Self.routeURL(
            baseURL: baseURL,
            template: RouterConstants.submitPathTemplate,
            path: path
        )
        let response = try await execute(deadline: deadline) { attempts in
            try await self.perform(
                url: url,
                method: "POST",
                body: body,
                idempotencyKey: idempotencyKey,
                deadline: deadline,
                attempts: attempts,
                // `200`, `201` or `202`. Deliberately wider than `run`'s single `200`, and
                // matching what the Python and TypeScript SDKs accept: on this route all three
                // mean "accepted", and what actually proves an acceptance is the `request_id`
                // in the body — which is required below, so a `2xx` without one still fails
                // rather than producing a handle addressing nothing.
                isSuccess: { (200...202).contains($0) }
            )
        }

        guard let root = RouterErrorMapping.jsonObject(from: response.data),
              let rawRequestId = root["request_id"].stringValue,
              !rawRequestId.isEmpty
        else { throw Self.invalidResponse(route: "submit", detail: "no request_id") }

        return RouterSubmitAcknowledgement(
            requestId: rawRequestId,
            encodedRequestId: try Self.validatedRequestId(rawRequestId),
            queuePosition: root["queue_position"].intValue,
            state: RouterRequestState(rawValue: root["status"].stringValue ?? RouterRequestState.inQueue.rawValue)
        )
    }

    // MARK: - Status

    /// `GET …/requests/{request_id}/status` — one reading, no polling.
    internal func requestStatus(
        path: ModelPath,
        requestId: String,
        encodedRequestId: String,
        deadline: ContinuousClock.Instant
    ) async throws -> RouterRequestStatus {
        let url = try Self.routeURL(
            baseURL: baseURL,
            template: RouterConstants.requestStatusPathTemplate,
            path: path,
            requestId: encodedRequestId
        )
        let response = try await execute(deadline: deadline) { attempts in
            try await self.perform(
                url: url,
                method: "GET",
                body: nil,
                idempotencyKey: nil,
                deadline: deadline,
                attempts: attempts,
                isSuccess: { $0 == 200 }
            )
        }

        guard let root = RouterErrorMapping.jsonObject(from: response.data),
              let rawState = root["status"].stringValue, !rawState.isEmpty
        else { throw Self.invalidResponse(route: "status", detail: "no status") }

        return RouterRequestStatus(
            requestId: requestId,
            // Capped because an unrecognised state is stored VERBATIM on a public
            // `RouterRequestState.unknown` a caller may log — and `status` is a
            // response-controlled string bounded by nothing tighter than the 1 MB body cap.
            // The same reasoning as `RouterErrorMapping`'s cap on an unknown error bucket.
            state: RouterRequestState(rawValue: Self.capped(rawState)),
            queuePosition: root["queue_position"].intValue,
            errorType: Self.reportedErrorType(root["error_type"].stringValue),
            // The server's hint, held to the queue's own ceiling BEFORE anyone sleeps on it —
            // see ``RouterRequestHandle/maximumRetryAfter``. Capped rather than dropped: an
            // over-long hint is still the server asking to be polled less often, and honouring
            // a minute of it is strictly better than falling back to a half-second schedule.
            retryAfter: RouterErrorMapping.retryAfterHint(headers: response.headers)
                .map { min($0, RouterRequestHandle.maximumRetryAfter) }
        )
    }

    /// The failure bucket a status body reported, or `nil`.
    ///
    /// A blank value reports nothing, and a value carrying the SDK's own reserved marker prefix
    /// is refused rather than repeated — the same rule
    /// ``RouterErrorMapping/isServerNameable(_:)`` enforces on `X-Comfy-Error-Type`, applied
    /// here so the queue path cannot become the one door a server walks a `comfy-sdk/…` bucket
    /// through.
    private static func reportedErrorType(_ raw: String?) -> RouterErrorType? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              RouterErrorMapping.isServerNameable(raw) else { return nil }
        return RouterErrorType(rawValue: capped(raw))
    }

    /// Upper bound, in Unicode scalars, on a response-controlled string this SDK retains on a
    /// public value. The same 128 `RouterErrorMapping` applies to an unrecognised error bucket.
    private static let responseFieldMaxLength = 128

    /// Measured in Unicode scalars rather than characters: one extended grapheme cluster can
    /// carry an unbounded run of combining scalars, so a `count`-based cap admits a megabyte of
    /// text under a `count` of 1.
    private static func capped(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count > responseFieldMaxLength else { return value }
        return String(String.UnicodeScalarView(scalars.prefix(responseFieldMaxLength)))
    }

    // MARK: - Result

    /// `GET …/requests/{request_id}` — the provider's native output.
    ///
    /// - Parameter idempotencyKey: The key the *submit* ran under, when it is known. Carried
    ///   onto the ``RouterRunResult`` so the queue path reports the same provenance the run path
    ///   does; `nil` on a handle rebuilt from ids alone, which never made a submit.
    internal func requestResult(
        path: ModelPath,
        encodedRequestId: String,
        idempotencyKey: String?,
        deadline: ContinuousClock.Instant
    ) async throws -> RouterRunResult {
        let url = try Self.routeURL(
            baseURL: baseURL,
            template: RouterConstants.requestResultPathTemplate,
            path: path,
            requestId: encodedRequestId
        )
        // `200` only. A `202` is the contract's "still running", and it carries the STATUS body
        // rather than an output — so accepting it here would hand the caller a `RouterRunResult`
        // whose `output` is a queue status and call it a finished generation. It falls through
        // to the mapping instead and surfaces as a `RouterError` with `httpStatus == 202`, which
        // is what ``RouterRequestHandle/result()`` documents.
        let response = try await execute(deadline: deadline) { attempts in
            try await self.perform(
                url: url,
                method: "GET",
                body: nil,
                idempotencyKey: nil,
                deadline: deadline,
                attempts: attempts,
                isSuccess: { $0 == 200 }
            )
        }

        // Deliberately NOT held to the "must be a JSON object" rule the status and submit bodies
        // are. This body is the partner model's own document, which Comfy does not re-envelope:
        // a provider that answers a bare array, a string, or bytes that are not JSON at all is
        // returning its output, not a malformed envelope, and `RouterRunResult.data` carries it
        // verbatim either way — exactly as the run route already behaves.
        let metadata = RouterErrorMapping.successMetadata(headers: response.headers)
        return RouterRunResult(
            data: response.data,
            output: Self.output(from: response.data),
            requestId: metadata.requestId,
            idempotencyKey: idempotencyKey,
            replayed: metadata.replayed
        )
    }

    // MARK: - Cancel

    /// `PUT …/requests/{request_id}/cancel` — **`PUT`**, which is the one thing about this
    /// route that is easy to get wrong by analogy with every other write in this SDK.
    internal func cancelRequest(
        path: ModelPath,
        encodedRequestId: String,
        deadline: ContinuousClock.Instant,
        maximumAttempts: Int? = nil
    ) async throws -> RouterCancelOutcome {
        let url = try Self.routeURL(
            baseURL: baseURL,
            template: RouterConstants.requestCancelPathTemplate,
            path: path,
            requestId: encodedRequestId
        )
        // `400` is admitted as a SUCCESS status here, and only here, so the body below can tell
        // the contract's `ALREADY_COMPLETED` — an outcome, not a failure — apart from an
        // ordinary `400`. Anything the body does not name is re-thrown as the Router error it
        // is, so widening the accepted set does not widen what is reported as success.
        let response = try await execute(deadline: deadline) { attempts in
            try await self.perform(
                url: url,
                method: "PUT",
                body: nil,
                idempotencyKey: nil,
                deadline: deadline,
                attempts: attempts,
                maximumAttempts: maximumAttempts,
                isSuccess: { $0 == 202 || $0 == 400 }
            )
        }

        if response.http.statusCode == 202 { return .cancellationRequested }

        let root = RouterErrorMapping.jsonObject(from: response.data)
        let reported = root?["status"].stringValue ?? root?["detail"].stringValue
        if reported?.uppercased() == "ALREADY_COMPLETED" { return .alreadyCompleted }

        throw ComfyError.router(
            RouterErrorMapping.routerError(
                status: response.http.statusCode,
                headers: response.headers,
                body: response.data,
                idempotencyKey: nil
            )
        )
    }

    /// One cancel, sent once, bounded short, and allowed to fail silently.
    ///
    /// Issued by ``subscribe(path:body:idempotencyKey:timeout:onQueueUpdate:)`` when its own
    /// deadline elapses or the calling task is cancelled. Two properties matter and neither is
    /// incidental:
    ///
    /// - **It runs detached.** A task cancellation makes every `await` in the current task throw
    ///   at once, so a cancel issued inline on that path would never reach the wire — which is
    ///   the only path where it matters most.
    /// - **Its failure is swallowed.** The caller is already throwing `.timeout` or
    ///   `.cancelled`; replacing that with a network error from the cleanup would report the
    ///   wrong thing and lose the one the caller can act on.
    /// - Note: The detached task calls back into this actor while `subscribe` — also on this
    ///   actor — is awaiting it. That is safe because Swift actors are **reentrant**: awaiting
    ///   `task.result` releases the actor, so the cancel can enter and run. It is the one
    ///   non-obvious thing about this function, and it is why the await is on `result` rather
    ///   than the work being done inline.
    internal func bestEffortCancel(path: ModelPath, encodedRequestId: String) async {
        let task = Task.detached { [self] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(Self.bestEffortCancelTimeout))
            _ = try? await cancelRequest(
                path: path,
                encodedRequestId: encodedRequestId,
                deadline: deadline,
                maximumAttempts: 1
            )
        }
        _ = await task.result
    }

    // MARK: - Polling

    /// Polls the status route until the request reaches a terminal state, reporting each change.
    ///
    /// **Poll-authoritative**: the status route decides when the request is done. Nothing here
    /// consults the result route's `202`, and nothing trusts the `status_url` / `response_url` /
    /// `cancel_url` the submit response carries — every URL is composed from the contract-pinned
    /// templates, because every request made from one carries the caller's credential.
    ///
    /// - Parameter deadline: The wall-clock stop for the whole watch — the poll requests, their
    ///   own re-sends, and the pauses between them alike. **The first poll is always made**: its
    ///   own bound is floored at ``minimumAttemptBudget`` even when the deadline has already
    ///   passed, so a budget that submit consumed still reads the status once rather than
    ///   reporting a timeout about a request nobody ever looked at.
    /// - Returns: The terminal status, which is always ``RouterRequestState/completed`` with no
    ///   reported failure — a reported one throws.
    /// - Throws: ``ComfyError/router(_:)`` when the terminal status names an `error_type`,
    ///   ``ComfyError/timeout`` at the deadline, ``ComfyError/cancelled`` on task cancellation.
    /// One observation reduced to the two fields a change is judged on.
    ///
    /// Not `RouterRequestStatus` itself: that also carries the server's `Retry-After`, which a
    /// conforming server is free to vary poll by poll — so equality on the whole struct would
    /// report "the queue moved" every time the hint changed and nothing else did.
    private struct Observation: Equatable {
        let state: RouterRequestState
        let queuePosition: Int?
    }

    @discardableResult
    internal func pollUntilTerminal(
        path: ModelPath,
        requestId: String,
        encodedRequestId: String,
        deadline: ContinuousClock.Instant,
        seeded: RouterRequestStatus? = nil,
        throwsOnCompletionFailure: Bool,
        onEvent: (@Sendable (RouterRequestStatus) -> Void)?
    ) async throws -> RouterRequestStatus {
        var delay = Self.pollInitialDelay
        // Seeded with what the caller has ALREADY reported — `subscribe` reports the submit
        // acknowledgement's own queue position before the first poll — so a first poll that
        // reads back the same position does not emit it twice.
        var lastObservation: Observation? = seeded.map {
            Observation(state: $0.state, queuePosition: $0.queuePosition)
        }
        var isFirstPoll = true

        while true {
            if !isFirstPoll {
                guard !Task.isCancelled else { throw ComfyError.cancelled }
                guard Self.seconds(ContinuousClock.now.duration(to: deadline)) > 0 else {
                    throw ComfyError.timeout
                }
            }

            let pollDeadline = isFirstPoll
                ? max(deadline, ContinuousClock.now.advanced(by: .seconds(Self.minimumAttemptBudget)))
                : deadline
            isFirstPoll = false

            let status = try await requestStatus(
                path: path,
                requestId: requestId,
                encodedRequestId: encodedRequestId,
                deadline: pollDeadline
            )

            // Collapsed on equality rather than reported every poll: a queue that has not moved
            // is not news, and a caller driving a progress view off this should not have to
            // de-duplicate it. A change in queue position IS a change.
            let observation = Observation(state: status.state, queuePosition: status.queuePosition)
            if observation != lastObservation {
                lastObservation = observation
                onEvent?(status)
            }

            if status.state.isTerminal {
                // Terminal is not the same as successful. A cancellation that took effect, a
                // provider failure and a content refusal all read `COMPLETED`; the bucket is
                // what tells them apart.
                //
                // Whether that bucket is THROWN depends on who is polling, and the split
                // mirrors the Python and TypeScript SDKs exactly. A caller COLLECTING —
                // `subscribe`, `handle.result()` — is asking for a result, so a completion that
                // reported a failure has to fail the call rather than be handed back as one. A
                // caller WATCHING — `handle.events()` — is asking for the queue's progress, and
                // the completion is the last thing that happened: it is yielded as an
                // observation carrying `errorType`, and the stream ends normally.
                if let errorType = status.errorType, throwsOnCompletionFailure {
                    SDKLog.routerRequestCompletedWithError(errorType: errorType)
                    throw ComfyError.router(
                        RouterError(
                            errorType: errorType,
                            httpStatus: 200,
                            detail: "Request \(requestId) completed with \(errorType.rawValue).",
                            requestId: status.requestId,
                            idempotencyKey: nil
                        )
                    )
                }
                return status
            }

            guard !Task.isCancelled else { throw ComfyError.cancelled }

            // The server's hint beats the schedule outright — it is the only party that knows
            // how long the queue actually is — and is already capped at
            // ``RouterRequestHandle/maximumRetryAfter`` by the time it gets here.
            let scheduled = status.retryAfter ?? delay
            // Clamped to what is left so the pause cannot outlive the deadline it is being
            // spent against: sleeping a full minute on a hint with two seconds of budget behind
            // it would report the timeout a minute late, and `timeout` is documented as a real
            // wall-clock stop.
            let remaining = Self.seconds(ContinuousClock.now.duration(to: deadline))
            let pause = min(scheduled, max(remaining, 0))
            if pause > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                } catch {
                    // `Task.sleep` throws only on cancellation.
                    throw ComfyError.cancelled
                }
            }

            // Advanced from the SCHEDULE, never from the server's hint: a single long
            // `Retry-After` must not permanently stretch a schedule the server is not otherwise
            // steering.
            delay = min(delay * Self.pollBackoffFactor, Self.pollMaximumDelay)
        }
    }

    /// Drives ``RouterRequestHandle/events(timeout:)``.
    internal func watch(
        path: ModelPath,
        requestId: String,
        encodedRequestId: String,
        timeout: TimeInterval,
        onEvent: @escaping @Sendable (RouterRequestStatus) -> Void
    ) async throws {
        try Self.validatePollTimeout(timeout)
        try await pollUntilTerminal(
            path: path,
            requestId: requestId,
            encodedRequestId: encodedRequestId,
            deadline: ContinuousClock.now.advanced(by: .seconds(timeout)),
            throwsOnCompletionFailure: false,
            onEvent: onEvent
        )
    }

    /// Drives ``RouterRequestHandle/result(timeout:)`` — poll to completion, then collect.
    ///
    /// An elapsed deadline throws WITHOUT issuing a cancel. The handle did not submit this
    /// request and does not own it; only `subscribe`, which did, cleans up after itself.
    internal func collectRequest(
        path: ModelPath,
        requestId: String,
        encodedRequestId: String,
        idempotencyKey: String?,
        timeout: TimeInterval,
        onEvent: (@Sendable (RouterRequestStatus) -> Void)?
    ) async throws -> RouterRunResult {
        try Self.validatePollTimeout(timeout)
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        try await pollUntilTerminal(
            path: path,
            requestId: requestId,
            encodedRequestId: encodedRequestId,
            deadline: deadline,
            throwsOnCompletionFailure: true,
            onEvent: onEvent
        )
        return try await requestResult(
            path: path,
            encodedRequestId: encodedRequestId,
            idempotencyKey: idempotencyKey,
            // Floored the same way the first poll is: a request that completed on the last poll
            // must still be collected, rather than lost to a deadline that elapsed between
            // reading "done" and asking for the output.
            deadline: max(
                deadline,
                ContinuousClock.now.advanced(by: .seconds(Self.minimumAttemptBudget))
            )
        )
    }

    /// A polling bound, which — unlike ``validateTimeout(_:)`` — admits **zero**.
    ///
    /// The floor `validateTimeout` enforces exists because a sub-second budget on the run route
    /// buys one billable POST with too little time to answer in. Nothing in that reasoning
    /// transfers to a poll: it is a cheap `GET`, nothing is dispatched or charged by making it,
    /// and the first poll is always made — so `0` is a meaningful budget here and reads "look
    /// once", which is what the TypeScript SDK's `timeoutMs: 0` means too. The upper bound and
    /// the finiteness check still apply, for the same reason they do there: `Duration.seconds(_:)`
    /// TRAPS on a non-finite or overflowing `Double`.
    internal static func validatePollTimeout(_ timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout >= 0, timeout <= 86_400 else {
            SDKLog.routerRejectedBeforeSend(reason: invalidTimeoutReason)
            throw ComfyError.serverRejected(reason: .other(invalidTimeoutReason))
        }
    }

    // MARK: - Subscribe

    /// Submit, poll, collect — the queued equivalent of one `run` call.
    internal func subscribe(
        path: ModelPath,
        body: Data,
        idempotencyKey: String,
        timeout: TimeInterval,
        onQueueUpdate: (@Sendable (RouterRequestStatus) -> Void)?
    ) async throws -> RouterRunResult {
        try Self.validateTimeout(timeout)
        // ONE deadline for the whole call, taken once and spent from — the submit, the polls,
        // their own re-sends, the pauses between them and the result fetch all draw on it. Same
        // monotonic clock as the run path, for the same reason: a `Date` deadline moves under an
        // NTP correction, and this window is minutes long.
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))

        let acknowledgement = try await submitRequest(
            path: path,
            body: body,
            idempotencyKey: idempotencyKey,
            deadline: deadline
        )
        // Reported from the acknowledgement's OWN state rather than assumed to be `IN_QUEUE`,
        // so a caller sees a queue position before the first poll rather than a schedule tick
        // later — and sees the right one if the server ever accepts a request already running.
        let submitted = RouterRequestStatus(
            requestId: acknowledgement.requestId,
            state: acknowledgement.state,
            queuePosition: acknowledgement.queuePosition
        )
        onQueueUpdate?(submitted)

        do {
            try await pollUntilTerminal(
                path: path,
                requestId: acknowledgement.requestId,
                encodedRequestId: acknowledgement.encodedRequestId,
                deadline: deadline,
                seeded: submitted,
                throwsOnCompletionFailure: true,
                onEvent: onQueueUpdate
            )
            return try await requestResult(
                path: path,
                encodedRequestId: acknowledgement.encodedRequestId,
                idempotencyKey: idempotencyKey,
                // The result fetch is inside the caller's budget too — it is part of the wait,
                // not a free extra — but it is floored the same way the first poll is, so a
                // request that completed on the last poll is still collected rather than lost to
                // a deadline that elapsed between reading "done" and asking for the output.
                deadline: max(
                    deadline,
                    ContinuousClock.now.advanced(by: .seconds(Self.minimumAttemptBudget))
                )
            )
        } catch {
            // ONLY the two outcomes where the caller is walking away from a request that is
            // still running. Every other failure — a provider error, a content refusal, a
            // cancellation that already took effect — is terminal server-side, so cancelling it
            // would be a pointless round trip on the way out.
            switch error as? ComfyError {
            case .timeout, .cancelled:
                await bestEffortCancel(path: path, encodedRequestId: acknowledgement.encodedRequestId)
            default:
                break
            }
            // Rethrown untouched. The cancel is cleanup; its own outcome is never the answer the
            // caller gets, which is why `bestEffortCancel` cannot throw at all.
            throw error
        }
    }

    // MARK: - One request

    /// One response off a queue route, with its headers already narrowed.
    internal struct RouteResponse: Sendable {
        let data: Data
        let http: HTTPURLResponse
        let headers: [String: String]
    }

    /// The wrapper every queue route call runs inside: one wall-clock stop, one 401 refresh,
    /// one per-call send budget.
    ///
    /// The same three-layer arrangement ``run(path:body:idempotencyKey:timeout:)`` uses, and in
    /// the same order — the deadline OUTSIDE `withAuthRetry`, so a 401 refresh spends the
    /// caller's budget rather than renewing it, and the attempt counter outside the operation,
    /// so the refresh's re-entry cannot restart the send budget from zero.
    private func execute<T: Sendable>(
        deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable (AttemptCounter) async throws -> T
    ) async throws -> T {
        let attempts = AttemptCounter()
        return try await Self.withWallClockDeadline(deadline) {
            try await self.transport.withAuthRetry {
                try await operation(attempts)
            }
        }
    }

    /// Sends one queue-route request, re-sending under the same key while the contract says a
    /// re-send collects rather than re-charges.
    ///
    /// Mirrors `collect`'s loop — the cancellation checks, the deadline guards, the attempt cap,
    /// the post-`applyAuth` re-sample, the 401 credential branch, the collect fit check — and
    /// shares its helpers (``collectDelay(status:error:)``, ``headerFields(of:)``,
    /// ``isUnauthorizedCredential(_:)``, ``redirectRefusal``) rather than reimplementing any of
    /// them. What it does not share is the success test: `collect` hard-codes `200` and builds a
    /// ``RouterRunResult``, where each queue route declares a different success status and a
    /// different body shape, so this one takes the test as a parameter and hands the raw
    /// response back.
    private func perform(
        url: URL,
        method: String,
        body: Data?,
        idempotencyKey: String?,
        deadline: ContinuousClock.Instant,
        attempts: AttemptCounter,
        maximumAttempts: Int? = nil,
        isSuccess: @Sendable (Int) -> Bool
    ) async throws -> RouteResponse {
        let cap = maximumAttempts ?? self.maximumAttempts

        while true {
            guard !Task.isCancelled else { throw ComfyError.cancelled }

            guard Self.seconds(ContinuousClock.now.duration(to: deadline)) > 0 else {
                throw ComfyError.timeout
            }

            guard attempts.count < cap else {
                throw attempts.lastRouterError.map(ComfyError.router) ?? ComfyError.timeout
            }
            attempts.count += 1

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            if let idempotencyKey {
                request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            }
            try await transport.applyAuth(to: &request)

            // Sampled AFTER `applyAuth`, which may fire a proactive OAuth refresh this deadline
            // does not bound — the same reason `collect` samples here rather than above.
            let sendBudget = Self.seconds(ContinuousClock.now.duration(to: deadline))
            guard sendBudget > 0 else { throw ComfyError.timeout }
            request.timeoutInterval = sendBudget

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(
                    for: request,
                    delegate: Self.redirectRefusal
                )
            } catch {
                throw Transport.translate(error)
            }

            guard let http = response as? HTTPURLResponse else {
                throw ComfyError.unknown(underlying: URLError(.badServerResponse))
            }
            let headers = Self.headerFields(of: http)

            if isSuccess(http.statusCode) {
                return RouteResponse(data: data, http: http, headers: headers)
            }

            if http.statusCode == 401, Self.isUnauthorizedCredential(http) {
                throw ComfyError.authInvalid
            }

            let routerError = RouterErrorMapping.routerError(
                status: http.statusCode,
                headers: headers,
                body: data,
                idempotencyKey: idempotencyKey
            )
            attempts.lastRouterError = routerError

            // `collectDelay` is the same table the run route uses, so a `403 not_enabled`, a
            // `409 invalid_input` and a `404 model_not_found` are all terminal here too — no
            // re-send, no sleep, the error straight back to the caller.
            guard attempts.count < cap,
                  let delay = Self.collectDelay(status: http.statusCode, error: routerError),
                  delay + Self.minimumAttemptBudget
                      <= Self.seconds(ContinuousClock.now.duration(to: deadline)) else {
                SDKLog.routerRunFailed(status: http.statusCode, errorType: routerError.errorType)
                throw ComfyError.router(routerError)
            }

            SDKLog.routerCollectRetry(
                status: http.statusCode,
                errorType: routerError.errorType,
                retryAfter: delay
            )
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                throw ComfyError.cancelled
            }
        }
    }

    /// The error for a queue response whose envelope this SDK cannot read.
    ///
    /// The submit `201` and the status `200` are Comfy-shaped envelopes with required fields —
    /// unlike the result body, which is the provider's own document and is passed through
    /// whatever it is. A missing `request_id` or `status` is a server that did not answer the
    /// contract, and inventing a value for it would hand the caller a handle addressing nothing
    /// or a status that silently reads as "still queued" forever.
    private static func invalidResponse(route: String, detail: String) -> ComfyError {
        SDKLog.routerInvalidResponse(route: route, detail: detail)
        return ComfyError.unknown(underlying: RouterInvalidResponseError(route: route, detail: detail))
    }
}

/// A Comfy Router queue response that is not the envelope the contract declares.
///
/// Surfaced through ``ComfyError/unknown(underlying:)``, as a distinct type rather than a bare
/// string so a caller can tell a malformed envelope apart from the transport failures that
/// share that case.
internal struct RouterInvalidResponseError: LocalizedError, Equatable {

    /// Which route answered — `"submit"` or `"status"`.
    internal let route: String

    /// What was wrong with it, in SDK terms. Never response text: the body is
    /// server-controlled, and this string is likely to be logged.
    internal let detail: String

    internal var errorDescription: String? {
        "The Comfy Router \(route) response is not the JSON object the contract declares "
            + "(\(detail))."
    }
}
