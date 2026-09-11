import Foundation

/// The transport behind ``RouterModels/run(_:input:idempotencyKey:timeout:)``.
///
/// Comfy Router's model-run route is *synchronous*: one `POST` holds open until the partner
/// model answers, and the only thing that makes that safe to retry is the `Idempotency-Key`.
/// So this type is a one-request-plus-collect-loop, not a poller — the loop re-sends the
/// **same bytes under the same key** for the two status/bucket pairings the contract says a
/// re-send collects (`409 concurrency_limit_exceeded` and `504 deadline_exceeded`, the only
/// two it declares `Retry-After` on), plus a `429` that some intermediary chose to give the
/// header, and throws for everything else.
///
/// Credential injection, the proactive OAuth refresh, the refresh-on-401 retry, and the
/// transport-error taxonomy are all borrowed from ``Transport`` rather than reimplemented —
/// see `applyAuth(to:)`, `withAuthRetry(perform:)` and `translate(_:)` there. A second copy
/// of any of them is how the Router surface would start authenticating differently from the
/// rest of the SDK.
internal actor RouterTransport {

    /// The characters that may appear unescaped in ONE path segment: `urlPathAllowed` less
    /// the separator itself.
    ///
    /// `urlPathAllowed` permits `/`, because it describes a whole path rather than a segment.
    /// Leaving it in would let a model ID that survived validation still re-shape the route —
    /// the reason each segment is encoded individually and then joined, rather than the ID
    /// being encoded whole.
    private static let pathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    private let session: URLSession
    private let baseURL: URL
    private let transport: Transport

    /// Refuses every redirect on the run route. Stateless, so one shared instance serves every
    /// attempt.
    private static let redirectRefusal = RouterRedirectRefusal()

    /// The budget a collect re-send must still have AFTER its `Retry-After` wait for the
    /// re-send to be worth making.
    ///
    /// A re-send under an established key is answered from that key's record or joins the
    /// generation already in flight, so it is a short round trip rather than a fresh model run
    /// — but it is not instant, and a bound below this would be spent on TLS setup alone. When
    /// less than this remains, the ``RouterError`` in hand is returned instead: a
    /// `.deadlineExceeded` naming the key and the request id is strictly more useful to the
    /// caller than the `.timeout` the doomed attempt would produce.
    private static let minimumAttemptBudget: TimeInterval = 5

    /// - Parameters:
    ///   - session: The client's own `URLSession` — already carrying `X-Comfy-Client` from
    ///     ``ComfySDKInfo/sessionConfiguration()``.
    ///   - baseURL: The Router host. ``RouterConstants/defaultBaseURL`` in production; a
    ///     redirect for tests and staging.
    ///   - transport: The client's ``Transport``, used purely for its credential handling.
    internal init(session: URLSession, baseURL: URL, transport: Transport) {
        self.session = session
        self.baseURL = baseURL
        self.transport = transport
    }

    // MARK: - Model ID

    /// The two path segments of a canonical `{provider}/{model}` Router model ID, each
    /// percent-encoded and ready to interpolate into the run route.
    internal struct ModelPath {
        let provider: String
        let model: String
    }

    /// Stable machine identifier reported for every malformed model ID.
    internal static let invalidModelIdReason = "invalid_model_id"

    /// Stable machine identifier for the one malformed shape that has a specific remedy: a
    /// three-segment ID.
    ///
    /// It is prefixed with ``invalidModelIdReason`` so a caller branching on the general
    /// identifier with `hasPrefix` still matches, while a caller that wants to tell the user
    /// *which* form failed can distinguish it.
    internal static let invalidModelIdVariantReason = "invalid_model_id_variant_unsupported"

    /// Stable machine identifier for a caller-supplied `Idempotency-Key` the contract cannot
    /// carry — empty, longer than the declared 255, or holding a character an HTTP header
    /// field value may not.
    internal static let invalidIdempotencyKeyReason = "invalid_idempotency_key"

    /// Stable machine identifier for a `timeout` that cannot bound anything: not finite, or
    /// not positive.
    internal static let invalidTimeoutReason = "invalid_timeout"

    /// Stable machine identifier for a Router base URL this SDK will not post a credential to.
    internal static let invalidBaseURLReason = "invalid_router_base_url"

    /// Splits and encodes a canonical Router model ID, or throws before any request is built.
    ///
    /// The rules mirror the TypeScript SDK's `parseModelId`, and they are validated here —
    /// client-side, ahead of the network — because every one of these shapes would otherwise
    /// reach the wire as a *different route* rather than as a rejected model: a missing
    /// segment posts to the catalog route, a `..` segment walks up out of `/v2/models/`, and
    /// a raw `/` inside a segment invents a path the contract does not declare. A `404` is
    /// the best case; a silent success against the wrong route is the worst.
    ///
    /// - Throws: ``ComfyError/serverRejected(reason:)`` carrying
    ///   ``ServerRejectionReason/other(_:)`` — ``invalidModelIdVariantReason`` for the
    ///   three-segment `{provider}/{model}/{variant}` form, ``invalidModelIdReason``
    ///   otherwise.
    internal static func parseModelId(_ modelId: String) throws -> ModelPath {
        let segments = modelId.components(separatedBy: "/")

        // The `{provider}/{model}[/{variant}]` form appears in the vendored spec's prose, but
        // the run route declares exactly two path parameters and `RouterModelId`'s pattern is
        // two segments joined by a single `/` — so a variant is not addressable here at all,
        // and the catalog can never hand one out. Named separately because "use
        // {provider}/{model}" is a remedy the caller can act on, which a bare
        // `invalid_model_id` is not. Matched on exactly three segments, because that remedy is
        // what the identifier promises: `a/b/c/d` is not a variant of anything, and the general
        // `invalid_model_id` is the accurate answer for it. Guarded on every segment being
        // non-empty so that `a//b` reports as the malformed ID it is rather than as a variant.
        if segments.count == 3, !segments.contains(where: \.isEmpty) {
            SDKLog.routerRejectedBeforeSend(reason: invalidModelIdVariantReason)
            throw ComfyError.serverRejected(reason: .other(invalidModelIdVariantReason))
        }

        guard segments.count == 2 else { throw invalidModelId() }

        var encoded: [String] = []
        encoded.reserveCapacity(2)
        for segment in segments {
            // `.` and `..` are refused rather than encoded: `%2E%2E` is not a traversal, but
            // it is also not a model, and passing it through would turn a caller's typo into
            // a `404` from a route it never meant to address.
            guard !segment.isEmpty, segment != ".", segment != ".." else { throw invalidModelId() }
            guard let escaped = segment.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed),
                  !escaped.isEmpty else { throw invalidModelId() }
            encoded.append(escaped)
        }

        return ModelPath(provider: encoded[0], model: encoded[1])
    }

    private static func invalidModelId() -> ComfyError {
        SDKLog.routerRejectedBeforeSend(reason: invalidModelIdReason)
        return ComfyError.serverRejected(reason: .other(invalidModelIdReason))
    }

    // MARK: - Idempotency key

    /// The upper bound the vendored spec declares on `Idempotency-Key`.
    private static let idempotencyKeyMaxLength = 255

    /// The key this call runs under: the caller's, once it is known to be carriable, or a
    /// freshly minted lowercase UUID.
    ///
    /// A supplied key is validated here — client-side, ahead of the network — for the same
    /// reason the model ID is: every rejected shape would otherwise reach the wire as
    /// something other than what the caller meant. An empty or whitespace-only key sends a
    /// BLANK header, which a server reads as no key at all, so the at-most-once billing
    /// guarantee the caller asked for quietly does not apply while
    /// ``RouterRunResult/idempotencyKey`` still reports the value they passed. A key holding
    /// CR or LF is a header-injection shape, and one past the declared 255 is outside the
    /// contract. None of these is worth a round trip to discover.
    ///
    /// The character rule is printable ASCII (`0x21...0x7E`), the header-token shape the
    /// contract's own UUID example sits inside. It subsumes the blank case — space is `0x20`
    /// — and rejects control characters and non-ASCII along with it.
    ///
    /// - Throws: ``ComfyError/serverRejected(reason:)`` carrying
    ///   ``ServerRejectionReason/other(_:)`` with ``invalidIdempotencyKeyReason``.
    internal static func validatedIdempotencyKey(_ supplied: String?) throws -> String {
        guard let supplied else { return UUID().uuidString.lowercased() }

        let scalars = supplied.unicodeScalars
        guard !scalars.isEmpty,
              scalars.count <= idempotencyKeyMaxLength,
              scalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            SDKLog.routerRejectedBeforeSend(reason: invalidIdempotencyKeyReason)
            throw ComfyError.serverRejected(reason: .other(invalidIdempotencyKeyReason))
        }
        return supplied
    }

    // MARK: - Timeout

    /// Refuses a `timeout` that cannot bound the call.
    ///
    /// The non-finite case is the one that matters. `Date().addingTimeInterval(.nan)` yields a
    /// NaN deadline, and `Date`'s `<=` is `!(rhs < lhs)`, which is `true` for NaN — so every
    /// deadline comparison below would pass and the collect loop would re-send billable
    /// requests until the task was cancelled. Zero and negative are refused in the same place
    /// because they express no bound either, and would otherwise still spend one billable
    /// request before the already-expired deadline stopped the next.
    ///
    /// - Throws: ``ComfyError/serverRejected(reason:)`` carrying
    ///   ``ServerRejectionReason/other(_:)`` with ``invalidTimeoutReason``.
    internal static func validateTimeout(_ timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0 else {
            SDKLog.routerRejectedBeforeSend(reason: invalidTimeoutReason)
            throw ComfyError.serverRejected(reason: .other(invalidTimeoutReason))
        }
    }

    // MARK: - Input

    /// Serialises the caller's `input` dictionary into the exact bytes every attempt under one
    /// key will send.
    ///
    /// Done ONCE, before the first attempt, and never again: the contract refuses a re-used key
    /// whose request *differs* with a `409 invalid_input` rather than replaying it, so every
    /// attempt under one key has to send the identical bytes.
    ///
    /// `.sortedKeys` is what extends that guarantee **across process launches**, and it is
    /// load-bearing rather than tidiness. Swift seeds `Dictionary`'s hashing per process, so the
    /// same `[String: Any]` serialises to a different key order in every run — measured, not
    /// theoretical. Without it the documented iOS recovery flow (persist the key, relaunch, call
    /// `run(..., idempotencyKey:)` again to collect) would hand Router the same key with
    /// reordered bytes and be refused instead of served, which is the one case that flow exists
    /// for. JSON object key order carries no meaning, so no provider can observe the difference.
    ///
    /// `isValidJSONObject` is checked first because `data(withJSONObject:)` answers an
    /// unrepresentable value with an Objective-C `NSInvalidArgumentException` — which is not a
    /// Swift `Error` and cannot be caught, so it would crash the caller's process instead of
    /// throwing.
    ///
    /// - Throws: ``ComfyError/unknown(underlying:)`` carrying the serialisation failure.
    internal static func serializeInput(_ input: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(input) else {
            throw ComfyError.unknown(underlying: RouterInputSerializationError())
        }
        do {
            return try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        } catch {
            throw ComfyError.unknown(underlying: error)
        }
    }

    // MARK: - Run

    /// Posts one model run and collects it, re-sending under the same key while the contract
    /// says a re-send collects rather than re-charges.
    ///
    /// - Parameters:
    ///   - path: The already-validated, already-encoded model ID segments.
    ///   - body: The serialised input. The same bytes are sent on every attempt.
    ///   - idempotencyKey: Minted once per `run` call by the caller, never per attempt.
    ///   - timeout: The caller's whole-call budget. Spent from once, as a deadline — never
    ///     handed to an individual attempt as a fresh copy of itself.
    internal func run(
        path: ModelPath,
        body: Data,
        idempotencyKey: String,
        timeout: TimeInterval
    ) async throws -> RouterRunResult {
        let url = try Self.runURL(baseURL: baseURL, path: path)
        // Fixed BEFORE `withAuthRetry`, so a 401 refresh spends the caller's budget rather
        // than renewing it — otherwise a credential that 401s on every attempt would reset
        // the deadline each time round and the bound would not be a bound.
        let deadline = Date().addingTimeInterval(timeout)

        return try await transport.withAuthRetry {
            try await self.collect(
                url: url,
                body: body,
                idempotencyKey: idempotencyKey,
                deadline: deadline
            )
        }
    }

    private func collect(
        url: URL,
        body: Data,
        idempotencyKey: String,
        deadline: Date
    ) async throws -> RouterRunResult {
        while true {
            // `Task.checkCancellation` throws `CancellationError`, which is not a `ComfyError`
            // and would surface as `.unknown` — so every cancellation point in this loop is
            // translated explicitly to `.cancelled`. Router has no server-side cancel
            // endpoint; a cancelled run keeps its key, and re-running with that key is how a
            // caller collects it later.
            guard !Task.isCancelled else { throw ComfyError.cancelled }

            // ONE clock, checked at the top of EVERY pass rather than only before a collect
            // sleep. `withAuthRetry` re-enters this loop from the beginning after a 401
            // refresh, so without this guard a refresh that landed past the deadline would
            // still fire a billable POST with a whole fresh budget behind it.
            //
            // Read as `timeIntervalSinceNow > 0` rather than `Date() < deadline` so a
            // non-finite deadline FAILS the guard: NaN compares false against everything,
            // which is the property that makes `Date`'s `<=` useless here.
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ComfyError.timeout }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            request.httpBody = body
            // The session default is 60s of idle time, which would cut a silent hold long
            // before the server's own deadline. Set per request rather than on the session:
            // the session is shared with the ComfyUI surface, whose requests want the default.
            //
            // Re-applied per attempt, never hoisted: after `withAuthRetry` refreshes, the
            // resend has to carry the NEW token.
            try await transport.applyAuth(to: &request)

            // Sampled AFTER `applyAuth`, not before it. `applyAuth` is not free: in
            // `oauthRefreshable` mode it may fire the proactive refresh, and in `.oauth` mode
            // it awaits a caller-supplied `tokenProvider` closure — round trips this deadline
            // does not bound. Reading `remaining` before that await and stamping it on the
            // request would hand the POST a bound generated before an unbounded wait, so a slow
            // refresh would still fire a billable request after the caller's wall-clock budget
            // had passed, carrying an over-generous idle timeout. Re-guarded here for the same
            // reason the top of the loop is guarded.
            //
            // What is LEFT of the caller's budget, never a fresh copy of it — `timeout` bounds
            // the whole call, so a re-send inherits the remainder rather than restarting the
            // clock. Note this narrows the per-attempt bound without being a wall-clock stop
            // on its own: `URLRequest.timeoutInterval` is an IDLE timeout that resets as data
            // arrives. The guards are what bound the call across attempts.
            let sendBudget = deadline.timeIntervalSinceNow
            guard sendBudget > 0 else { throw ComfyError.timeout }
            request.timeoutInterval = sendBudget

            let data: Data
            let response: URLResponse
            do {
                // `delegate:` rather than a session-level delegate because the session is
                // SHARED with the ComfyUI surface, which follows redirects normally. Scoping
                // the refusal to this task leaves that surface untouched.
                (data, response) = try await session.data(
                    for: request,
                    delegate: Self.redirectRefusal
                )
            } catch {
                // `.offline` / `.timeout` / `.network` / `.cancelled`, thrown as-is. The
                // outcome of a request that failed in transit is UNKNOWN — it may have run and
                // been charged — so this is never retried here. The caller collects it by
                // re-running with the same `idempotencyKey:`.
                throw Transport.translate(error)
            }

            guard let http = response as? HTTPURLResponse else {
                throw ComfyError.unknown(underlying: URLError(.badServerResponse))
            }
            let headers = Self.headerFields(of: http)

            // `200` exactly, not the whole `2xx` class. The run route is synchronous and the
            // contract declares ONE success: a `200` whose body is the model's finished output.
            // A `202`/`204`/`206` from a changed or misconfigured Router means something other
            // than "this run is done", and accepting it here would hand the caller a
            // `RouterRunResult` with `.null` output and no way to tell that from a model that
            // genuinely returned nothing. Anything else falls through to the mapping below and
            // surfaces as an error the caller can see.
            if http.statusCode == 200 {
                let metadata = RouterErrorMapping.successMetadata(headers: headers)
                return RouterRunResult(
                    data: data,
                    output: Self.output(from: data),
                    requestId: metadata.requestId,
                    idempotencyKey: idempotencyKey,
                    replayed: metadata.replayed
                )
            }

            // A 401 that names no bucket, or names `unauthorized`, is the credential being
            // refused BEFORE the handler — nothing ran and nothing was recorded against the
            // key. Thrown as `.authInvalid` from inside `withAuthRetry` so an OAuth client
            // refreshes and re-sends under the same key. A 401 carrying any other bucket is a
            // Router-level refusal and falls through to the mapping below.
            if http.statusCode == 401, Self.isUnauthorizedCredential(http) {
                throw ComfyError.authInvalid
            }

            let routerError = RouterErrorMapping.routerError(
                status: http.statusCode,
                headers: headers,
                body: data,
                idempotencyKey: idempotencyKey
            )

            // The wait has to fit, AND the attempt after it has to be worth making. Without
            // `minimumAttemptBudget` a `Retry-After: 30` accepted with 30.2s left would sleep
            // 30s and then re-send with a 0.2s bound — a near-certain client-side failure that
            // throws away the `.router(deadlineExceeded)` already in hand (which carries the
            // request id, the `Retry-After` and the key, and tells the caller the generation is
            // still collectable) and replaces it with a bare `.timeout` the docs define as an
            // UNKNOWN outcome — with nothing to collect under at all when the key was defaulted.
            //
            // `timeIntervalSince(...) <= 0` rather than `<= deadline`: `Date`'s `<=` desugars
            // to `!(rhs < lhs)`, which is TRUE for a NaN deadline and would leave this loop
            // unbounded. A NaN budget is refused at the public boundary, so this is the second
            // of two locks on the same door.
            guard let delay = Self.collectDelay(status: http.statusCode, error: routerError),
                  Date().addingTimeInterval(delay + Self.minimumAttemptBudget)
                      .timeIntervalSince(deadline) <= 0 else {
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
                // `Task.sleep` throws only on cancellation.
                throw ComfyError.cancelled
            }
        }
    }

    // MARK: - Response reading

    /// How long to wait before re-sending this response's request under the same key, or `nil`
    /// when the contract does not say a re-send collects.
    ///
    /// Every pairing requires `Retry-After` — the header is the server telling us the call is
    /// still collectable, so its *absence* is a refusal to say so and is never second-guessed
    /// with a delay of our own.
    ///
    /// The contract declares that header on exactly two answers, and those are the two the
    /// collect loop exists for:
    ///
    /// - `409 concurrency_limit_exceeded` — another call is already in flight under this key;
    ///   re-sending the same key joins it.
    /// - `504 deadline_exceeded` — Comfy stopped holding the connection at its own bound while
    ///   the generation kept running; the same key collects it.
    ///
    /// The `429` case below is not a third contract pairing but tolerance for an intermediary
    /// that adds `Retry-After` to a rate-limit answer of its own — see the comment on it.
    ///
    /// Everything else throws, and the exclusions matter as much as the inclusions:
    /// `409 invalid_input` means the key is consumed and unreplayable (a new key is the only
    /// remedy, and re-sending would loop on the same refusal), and a `5xx` outside the pairing
    /// above has no contract saying anything is still running to collect.
    private static func collectDelay(status: Int, error: RouterError) -> TimeInterval? {
        guard let retryAfter = error.retryAfter else { return nil }

        let collectable: Bool
        switch status {
        // NOT dead code, and not to be deleted as such. The vendored spec declares
        // `Retry-After` on only two answers — the `409 concurrency_limit_exceeded` and the
        // `504 deadline_exceeded` below — so a CONFORMING server's `429` carries none and
        // never reaches this line, because `collectDelay` has already returned `nil` above.
        // It stays as tolerance for an intermediary that adds the header to a `429` it is
        // rate-limiting: honouring an explicit "ask again in N seconds" is the right answer
        // to that, and costs nothing when nobody sends it.
        case 429: collectable = true
        case 409: collectable = error.errorType == .concurrencyLimitExceeded
        case 504: collectable = error.errorType == .deadlineExceeded
        default: collectable = false
        }
        guard collectable else { return nil }

        // `Retry-After` is server-controlled, and `UInt64(_:)` on an out-of-range `Double`
        // traps. A value this large cannot fit any sane deadline anyway, so refusing it here
        // is the same outcome the deadline check would reach — minus the crash.
        let nanoseconds = retryAfter * 1_000_000_000
        guard nanoseconds.isFinite, nanoseconds >= 0, nanoseconds < Double(UInt64.max) else {
            return nil
        }
        return retryAfter
    }

    /// Whether a `401` is the plain credential refusal that an OAuth refresh can fix.
    ///
    /// `X-Comfy-Error-Type` absent (or blank) or equal to `unauthorized`. Read off the
    /// response rather than off the mapped ``RouterError`` on purpose: the mapping falls back
    /// to the *body's* `error_type` when the header is absent, and a body that names some
    /// other bucket must not suppress the refresh the header's silence calls for.
    private static func isUnauthorizedCredential(_ http: HTTPURLResponse) -> Bool {
        guard let raw = http.value(forHTTPHeaderField: "X-Comfy-Error-Type")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return true
        }
        return raw == RouterErrorType.unauthorized.rawValue
    }

    /// The model's native JSON output as a navigable value, or ``RouterJSON/null``.
    ///
    /// A body that is not JSON degrades to `.null` rather than failing the call: the run
    /// succeeded, and ``RouterRunResult/data`` still carries the bytes byte-for-byte, so a
    /// caller that knows better than this parser can still read them.
    private static func output(from data: Data) -> RouterJSON {
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return .null }
        return RouterJSON(any: parsed)
    }

    /// `allHeaderFields` narrowed to `[String: String]` for ``RouterErrorMapping``.
    ///
    /// A non-`String` value is rendered rather than dropped — `URLSession` hands back
    /// `String` values in practice, but a dropped header would silently disable the
    /// `Retry-After` collect path, and a rendered one at worst fails to parse.
    private static func headerFields(of response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        headers.reserveCapacity(response.allHeaderFields.count)
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String else { continue }
            headers[name] = value as? String ?? String(describing: value)
        }
        return headers
    }

    // MARK: - URL

    /// `{baseURL}/v2/models/{provider}/{model}`, built from the contract-pinned template.
    ///
    /// The base is VALIDATED rather than trusted. `routerBaseURL` is a public injection point
    /// and every run stamps the client's credential onto the request this builds, so the two
    /// things that must not happen quietly are posting it somewhere else and posting it in
    /// clear:
    ///
    /// - **A query or a fragment on the base does not fail loudly when a route is appended.**
    ///   It re-parses. `https://host/?x=1` plus the route is a POST to `https://host/` — the
    ///   HOST ROOT — with the whole route buried in the query string and the credential
    ///   attached. A `404` would be the good outcome; it is not the likely one.
    /// - **`https` is required** because the credential travels in a header. Over `http` it
    ///   would go out readable, and a non-TLS Router host is not a shape this SDK supports.
    ///
    /// Composition goes through `URLComponents.percentEncodedPath` rather than
    /// `appendingPathComponent`, which percent-encodes what it is given and would double-escape
    /// segments ``parseModelId(_:)`` has already encoded. Trailing slashes on the base are
    /// trimmed so a host written either way resolves to the same route rather than to `//v2/…`.
    ///
    /// - Throws: ``ComfyError/serverRejected(reason:)`` carrying
    ///   ``ServerRejectionReason/other(_:)`` with ``invalidBaseURLReason``.
    private static func runURL(baseURL: URL, path: ModelPath) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil,
              components.fragment == nil,
              // Userinfo is refused for the same reason the query is, and it hides better.
              // `https://api.comfy.org@evil.test` parses as user `api.comfy.org` and host
              // `evil.test` — verified, not assumed — so it clears every check above while
              // reading, to anyone auditing the configured string, as the real Router host.
              // Every run would then post the body, the `Idempotency-Key` and the credential
              // to `evil.test`.
              components.user == nil,
              components.password == nil else {
            throw invalidBaseURL()
        }

        let route = RouterConstants.runPathTemplate
            .replacingOccurrences(of: "{provider}", with: path.provider)
            .replacingOccurrences(of: "{model}", with: path.model)

        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + route

        guard let url = components.url else { throw invalidBaseURL() }
        return url
    }

    private static func invalidBaseURL() -> ComfyError {
        SDKLog.routerRejectedBeforeSend(reason: invalidBaseURLReason)
        return ComfyError.serverRejected(reason: .other(invalidBaseURLReason))
    }
}

/// Refuses to follow a redirect on the model-run route.
///
/// `URLSession` follows `3xx` by default, and every validation `runURL(baseURL:path:)` performs
/// — `https`, a host, no query, no fragment — describes the URL the SDK *composed*, not a hop
/// target a server picked afterwards. Following one would defeat all of it, in two distinct
/// ways, both with the caller's credential attached:
///
/// - **`307`/`308` re-send the method and body**, so the request bytes, the `Idempotency-Key`
///   and the `X-API-Key`/`Authorization` header would all be replayed to whatever host the
///   redirect named — over `http`, or off-origin, with nothing left to stop it.
/// - **`301`/`302`/`303` rewrite the `POST` to a `GET`** of the same path, and that path is a
///   route the contract declares: `GET /v2/models/{provider}/{model}` is the per-model catalog
///   read. Its `200` would sail through the success branch and be handed back as a finished
///   `RouterRunResult` whose `output` is a catalog document — a run that never ran, reported as
///   one that did.
///
/// Returning `nil` from the delegate hands the `3xx` itself back as the response, so it falls
/// to the status handling below and surfaces as an error rather than silently succeeding.
///
/// Holds no state, so the single shared instance is safe to reuse across concurrent attempts —
/// which is what `@unchecked Sendable` is asserting here.
///
/// `internal` rather than file-private so the refusal itself can be asserted directly in tests:
/// a `URLProtocol` stub hands a `3xx` straight back without engaging `URLSession`'s redirect
/// machinery, so an end-to-end stub CANNOT tell a refused redirect from a followed one.
internal final class RouterRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The `input` handed to ``RouterModels/run(_:input:idempotencyKey:timeout:)`` is not
/// representable as JSON.
///
/// Surfaced through ``ComfyError/unknown(underlying:)``. It is a distinct type rather than a
/// bare string so a caller can tell "your dictionary is not JSON" — a programming error, fixed
/// in the caller — apart from the transport failures that share that case.
internal struct RouterInputSerializationError: LocalizedError {
    internal var errorDescription: String? {
        "The `input` dictionary is not representable as JSON. Every value must be a String, "
            + "a number, a Bool, NSNull, or an Array/Dictionary of those; Dictionary keys must "
            + "be Strings, and Double values must be finite."
    }
}
