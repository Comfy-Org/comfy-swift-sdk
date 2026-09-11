import Foundation

/// The transport behind ``RouterModels/run(_:input:idempotencyKey:timeout:)``.
///
/// Comfy Router's model-run route is *synchronous*: one `POST` holds open until the partner
/// model answers, and the only thing that makes that safe to retry is the `Idempotency-Key`.
/// So this type is a one-request-plus-collect-loop, not a poller — the loop re-sends the
/// **same bytes under the same key** for exactly the three status/bucket pairings the
/// contract says a re-send collects, and throws for everything else.
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
        // `invalid_model_id` is not. Guarded on every segment being non-empty so that `a//b`
        // reports as the malformed ID it is rather than as a variant.
        if segments.count > 2, !segments.contains(where: \.isEmpty) {
            SDKLog.routerInvalidModelId(reason: invalidModelIdVariantReason)
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
        SDKLog.routerInvalidModelId(reason: invalidModelIdReason)
        return ComfyError.serverRejected(reason: .other(invalidModelIdReason))
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
    ///   - timeout: Both the per-request `timeoutInterval` and the span of the collect
    ///     deadline, measured from the first attempt.
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
                timeout: timeout,
                deadline: deadline
            )
        }
    }

    private func collect(
        url: URL,
        body: Data,
        idempotencyKey: String,
        timeout: TimeInterval,
        deadline: Date
    ) async throws -> RouterRunResult {
        while true {
            // `Task.checkCancellation` throws `CancellationError`, which is not a `ComfyError`
            // and would surface as `.unknown` — so every cancellation point in this loop is
            // translated explicitly to `.cancelled`. Router has no server-side cancel
            // endpoint; a cancelled run keeps its key, and re-running with that key is how a
            // caller collects it later.
            guard !Task.isCancelled else { throw ComfyError.cancelled }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            request.httpBody = body
            // The session default is 60s of idle time, which would cut a silent hold long
            // before the server's own deadline. Set per request rather than on the session:
            // the session is shared with the ComfyUI surface, whose requests want the default.
            request.timeoutInterval = timeout
            // Re-applied per attempt, never hoisted: after `withAuthRetry` refreshes, the
            // resend has to carry the NEW token.
            try await transport.applyAuth(to: &request)

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
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

            if (200..<300).contains(http.statusCode) {
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

            guard let delay = Self.collectDelay(status: http.statusCode, error: routerError),
                  Date().addingTimeInterval(delay) <= deadline else {
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
    /// Three pairings, each requiring `Retry-After` — the header is the server telling us the
    /// call is still collectable, so its *absence* is a refusal to say so and is never
    /// second-guessed with a delay of our own:
    ///
    /// - `429` — the workspace is at its concurrency or rate allowance; the call never started.
    /// - `409 concurrency_limit_exceeded` — another call is already in flight under this key;
    ///   re-sending the same key joins it.
    /// - `504 deadline_exceeded` — Comfy stopped holding the connection at its own bound while
    ///   the generation kept running; the same key collects it.
    ///
    /// Everything else throws, and the exclusions matter as much as the inclusions:
    /// `409 invalid_input` means the key is consumed and unreplayable (a new key is the only
    /// remedy, and re-sending would loop on the same refusal), and a `5xx` outside the pairing
    /// above has no contract saying anything is still running to collect.
    private static func collectDelay(status: Int, error: RouterError) -> TimeInterval? {
        guard let retryAfter = error.retryAfter else { return nil }

        let collectable: Bool
        switch status {
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
    /// Composed by string rather than with `appendingPathComponent`, which percent-encodes
    /// what it is given and would double-escape segments that are already encoded. Trailing
    /// slashes on the base are trimmed so a staging host written either way resolves to the
    /// same route instead of to `//v2/...`.
    private static func runURL(baseURL: URL, path: ModelPath) throws -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }

        let route = RouterConstants.runPathTemplate
            .replacingOccurrences(of: "{provider}", with: path.provider)
            .replacingOccurrences(of: "{model}", with: path.model)

        guard let url = URL(string: base + route) else {
            throw ComfyError.unknown(underlying: URLError(.badURL))
        }
        return url
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
