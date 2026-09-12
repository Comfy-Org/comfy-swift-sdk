//
//  RouterRunTests.swift
//  ComfySwiftSDKTests
//
//  `client.models.run(_:input:)` end to end against the `TestURLProtocol` stub: the request
//  it composes, the result it builds, the collect loop's three re-sendable pairings and the
//  refusals it must NOT re-send, the deadline, the 401 refresh, model-ID validation, and
//  cancellation.
//
//  Two things worth knowing before reading the collect-loop tests:
//
//  * `Retry-After: 1`, never `0`. The vendored contract declares a minimum of 1 and
//    `RouterErrorMapping` reads anything below it as "no advice" (`retryAfter == nil`), which
//    is deliberately *not* collectable — a `0` must never become an immediate re-send. So the
//    smallest value that exercises a re-send at all is `1`, and those tests each spend about
//    a second sleeping. That is the sleep under test, not incidental slowness.
//  * Request counts are the assertion that matters. "One result, two requests, identical key
//    and body bytes" is what distinguishes a collect from a second billable call.
//

import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("RouterRun — client.models.run over the Comfy Router surface", .serialized)
struct RouterRunTests {

    // MARK: - Recording stub

    /// Every request the stub saw, in order, with its body already drained.
    private final class RequestLog: @unchecked Sendable {
        struct Entry {
            let url: URL?
            let method: String?
            let headers: [String: String]
            let body: Data?
            let timeoutInterval: TimeInterval
        }

        private let lock = NSLock()
        private var _entries: [Entry] = []

        func record(_ request: URLRequest) {
            let entry = Entry(
                url: request.url,
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.drainBody(request),
                timeoutInterval: request.timeoutInterval
            )
            lock.lock(); defer { lock.unlock() }
            _entries.append(entry)
        }

        var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return _entries }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _entries.count }

        /// `URLSession` may hand a body to `URLProtocol` as a stream rather than as
        /// `httpBody`, so both forms are read.
        private static func drainBody(_ request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    /// One stubbed HTTP response.
    private struct Stub {
        let status: Int
        let headers: [String: String]
        let body: String

        init(_ status: Int, headers: [String: String] = [:], body: String = "{}") {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    /// Installs a stub that answers the Nth request with `responses[N]`, recording each one.
    ///
    /// The last entry is repeated if more requests arrive than were scripted — a test that
    /// over-sends then fails on its *count* assertion, with the extra requests visible, rather
    /// than on an opaque `badURL` from the stub running dry.
    private func installStub(_ responses: [Stub], log: RequestLog) {
        TestURLProtocol.install { request in
            log.record(request)
            let index = min(log.count - 1, responses.count - 1)
            let stub = responses[index]
            var headers = stub.headers
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (response, Data(stub.body.utf8))
        }
    }

    // MARK: - Fixtures

    private static let apiKey = "router-test-api-key"
    private static let bearerToken = "router-test-bearer-token"
    private static let cloudBaseURL = URL(string: "https://cloud.comfy.org")!
    private static let modelId = "bfl/flux-2-pro"
    private static let expectedURL = "https://api.comfy.org/v2/models/bfl/flux-2-pro"
    private static let imageOutput = #"{"images":[{"url":"https://cdn.example.test/a.png"}]}"#

    /// A `RouterModels` wired to the stub session, with the same `Transport` the real client
    /// shares with it — so credential injection and the refresh-on-401 retry are the
    /// production code paths, not test doubles.
    private func makeModels(
        credential: ComfyCredential = .apiKey(apiKey),
        baseURL: URL = RouterModels.defaultBaseURL
    ) -> RouterModels {
        let session = TestURLProtocol.makeStubSession()
        let transport = Transport(
            session: session,
            baseURL: Self.cloudBaseURL,
            credential: credential
        )
        return RouterModels(
            baseURL: baseURL,
            transport: RouterTransport(session: session, baseURL: baseURL, transport: transport)
        )
    }

    /// The stable machine identifier off a pre-flight `.serverRejected(.other(_))`, or `nil`.
    private static func rejectionIdentifier(_ error: any Error) -> String? {
        guard case .serverRejected(let reason)? = error as? ComfyError,
              case .other(let identifier) = reason else { return nil }
        return identifier
    }

    private static func routerError(from error: any Error) -> RouterError? {
        guard case .router(let routerError)? = error as? ComfyError else { return nil }
        return routerError
    }

    // MARK: - Happy path

    @Test("happy path: canonical URL, POST, JSON headers, a minted lowercase-UUID key, the 660s budget, and the parsed output")
    func happy_path_composes_the_contract_request_and_reads_the_output() async throws {
        let log = RequestLog()
        installStub(
            [Stub(200, headers: ["X-Comfy-Request-Id": "req-abc-123"], body: Self.imageOutput)],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let input: [String: Any] = ["prompt": "a cat", "width": 1024]
        let result = try await makeModels().run(Self.modelId, input: input)

        #expect(log.count == 1)
        let sent = try #require(log.entries.first)
        #expect(sent.url?.absoluteString == Self.expectedURL)
        #expect(sent.method == "POST")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.headers["Accept"] == "application/json")
        #expect(sent.headers["X-API-Key"] == Self.apiKey)
        #expect(sent.headers["Authorization"] == nil)
        // The first attempt gets what is left of the budget, which is the whole of it less
        // the microseconds spent composing the request — so bounded, not equal.
        #expect(sent.timeoutInterval <= RouterModels.defaultTimeout)
        #expect(sent.timeoutInterval > RouterModels.defaultTimeout - 5)
        #expect(RouterModels.defaultTimeout == 660)

        // Minted, not supplied: a lowercase UUID.
        let key = try #require(sent.headers["Idempotency-Key"])
        #expect(UUID(uuidString: key) != nil)
        #expect(key == key.lowercased())
        #expect(result.idempotencyKey == key)

        // The body is the caller's input, byte-for-byte as `JSONSerialization` wrote it.
        let expectedBody = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        #expect(sent.body == expectedBody)

        #expect(result.output["images"][0]["url"].stringValue == "https://cdn.example.test/a.png")
        #expect(result.data == Data(Self.imageOutput.utf8))
        #expect(result.requestId == "req-abc-123")
        #expect(result.replayed == false)
    }

    @Test("OAuth mode sends Authorization: Bearer and no API-key header")
    func oauth_mode_sends_a_bearer_header() async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let models = makeModels(credential: .oauth(tokenProvider: { Self.bearerToken }))
        _ = try await models.run(Self.modelId, input: ["prompt": "a cat"])

        let sent = try #require(log.entries.first)
        #expect(sent.headers["Authorization"] == "Bearer \(Self.bearerToken)")
        #expect(sent.headers["X-API-Key"] == nil)
    }

    @Test("a supplied idempotency key is sent verbatim, and Idempotent-Replayed reads through")
    func supplied_key_is_verbatim_and_replayed_reads_through() async throws {
        let log = RequestLog()
        installStub(
            [Stub(200, headers: ["Idempotent-Replayed": "true"], body: Self.imageOutput)],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let suppliedKey = "caller-supplied-key-0001"
        let result = try await makeModels().run(
            Self.modelId,
            input: ["prompt": "a cat"],
            idempotencyKey: suppliedKey
        )

        #expect(log.entries.first?.headers["Idempotency-Key"] == suppliedKey)
        #expect(result.idempotencyKey == suppliedKey)
        #expect(result.replayed == true)
    }

    @Test("a non-JSON 2xx body still returns, with output .null and data carrying the bytes")
    func non_json_success_body_degrades_to_null_output() async throws {
        let log = RequestLog()
        installStub([Stub(200, headers: ["Content-Type": "text/plain"], body: "not json")], log: log)
        defer { TestURLProtocol.uninstall() }

        let result = try await makeModels().run(Self.modelId, input: ["prompt": "a cat"])

        #expect(result.output == .null)
        #expect(result.data == Data("not json".utf8))
    }

    @Test("decode(_:) reads the model's own output into a Decodable of the caller's")
    func decode_reads_the_native_output() async throws {
        struct Output: Decodable, Equatable {
            struct Image: Decodable, Equatable { let url: String }
            let images: [Image]
        }
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let result = try await makeModels().run(Self.modelId, input: ["prompt": "a cat"])
        let decoded = try result.decode(Output.self)
        #expect(decoded == Output(images: [.init(url: "https://cdn.example.test/a.png")]))
    }

    // MARK: - Collect loop

    /// The two status/bucket pairings the contract says a same-key re-send collects — the
    /// only two it declares `Retry-After` on. `Retry-After: 1` is the contract's minimum — see
    /// the note at the top of this file.
    ///
    /// A `429` is deliberately NOT here: the spec's `Retry-After` is declared on the `409` and
    /// the `504` alone, so a conforming server's `429` carries none and is terminal. The
    /// separate test below covers the branch that tolerates one if an intermediary adds it.
    @Test(
        "collect loop re-sends the same key and the same bytes",
        arguments: [
            (504, "deadline_exceeded"),
            (409, "concurrency_limit_exceeded")
        ]
    )
    func collect_loop_resends_same_key_and_bytes(status: Int, errorType: String) async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(
                    status,
                    headers: ["X-Comfy-Error-Type": errorType, "Retry-After": "1"],
                    body: #"{"error_type":"\#(errorType)","detail":"still running"}"#
                ),
                Stub(200, body: Self.imageOutput)
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let input: [String: Any] = ["prompt": "a cat"]
        let expectedBody = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let result = try await makeModels().run(Self.modelId, input: input)

        #expect(log.count == 2, "expected exactly one re-send, saw \(log.count) requests")
        let sent = log.entries
        #expect(sent.count == 2)
        #expect(sent[0].headers["Idempotency-Key"] == sent[1].headers["Idempotency-Key"])
        #expect(sent[0].headers["Idempotency-Key"] == result.idempotencyKey)
        #expect(sent[0].body == sent[1].body)
        #expect(sent[1].body == expectedBody)
        #expect(result.output["images"][0]["url"].stringValue == "https://cdn.example.test/a.png")
    }

    /// The contract declares `Retry-After` on the `409` and the `504` only, so a conforming
    /// `429` is terminal — covered by `missing_retry_after_is_never_resent`. This pins the
    /// branch that still honours one when an intermediary adds it, so nobody deletes it as
    /// dead code.
    @Test("a 429 carrying a Retry-After is tolerated even though the contract declares none")
    func rate_limited_429_with_retry_after_is_still_collected() async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(
                    429,
                    headers: ["X-Comfy-Error-Type": "rate_limited", "Retry-After": "1"],
                    body: #"{"error_type":"rate_limited","detail":"slow down"}"#
                ),
                Stub(200, body: Self.imageOutput)
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let result = try await makeModels().run(Self.modelId, input: ["prompt": "a cat"])

        #expect(log.count == 2)
        #expect(log.entries[0].headers["Idempotency-Key"] == log.entries[1].headers["Idempotency-Key"])
        #expect(result.output["images"][0]["url"].stringValue == "https://cdn.example.test/a.png")
    }

    @Test("409 invalid_input is terminal — the key is consumed, so exactly one request goes out")
    func invalid_input_409_is_never_resent() async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(
                    409,
                    headers: ["X-Comfy-Error-Type": "invalid_input", "Retry-After": "1"],
                    body: #"{"error_type":"invalid_input","detail":"key already used for a different request"}"#
                ),
                Stub(200, body: Self.imageOutput)
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"])
        })
        let routerError = try #require(Self.routerError(from: thrown))
        #expect(routerError.errorType == .invalidInput)
        #expect(routerError.httpStatus == 409)
        // The `Retry-After` is present and would have been honoured on a `concurrency_limit_exceeded`.
        // `invalid_input` says the key is consumed and unreplayable, so nothing is re-sent.
        #expect(log.count == 1)
    }

    @Test("a 4xx with no Retry-After is never re-sent")
    func missing_retry_after_is_never_resent() async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(429, headers: ["X-Comfy-Error-Type": "rate_limited"], body: #"{"detail":"slow down"}"#),
                Stub(200, body: Self.imageOutput)
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"])
        })
        let routerError = try #require(Self.routerError(from: thrown))
        #expect(routerError.errorType == .rateLimited)
        #expect(routerError.retryAfter == nil)
        #expect(log.count == 1)
    }

    @Test("a 500 is never re-sent — no contract pairing says anything is still collectable")
    func internal_error_is_never_resent() async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(500, headers: ["Retry-After": "1"], body: #"{"detail":"boom"}"#),
                Stub(200, body: Self.imageOutput)
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"])
        })
        let routerError = try #require(Self.routerError(from: thrown))
        #expect(routerError.errorType == .internalError)
        #expect(log.count == 1)
    }

    @Test("a Retry-After past the remaining budget throws the RouterError without sleeping")
    func retry_after_beyond_the_deadline_throws_immediately() async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(
                    504,
                    headers: ["X-Comfy-Error-Type": "deadline_exceeded", "Retry-After": "30"],
                    body: #"{"error_type":"deadline_exceeded","detail":"comfy stopped holding"}"#
                ),
                Stub(200, body: Self.imageOutput)
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let started = Date()
        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"], timeout: 5)
        })
        let elapsed = Date().timeIntervalSince(started)

        let routerError = try #require(Self.routerError(from: thrown))
        #expect(routerError.errorType == .deadlineExceeded)
        #expect(routerError.retryAfter == 30)
        #expect(log.count == 1)
        #expect(elapsed < 5, "threw after \(elapsed)s — it slept on a Retry-After it should have refused")
    }

    @Test("a Retry-After that fits but leaves no room for the re-send throws the RouterError instead")
    func retry_after_leaving_too_little_for_the_resend_throws_immediately() async throws {
        // `Retry-After: 1` fits inside a 1.5s budget on its own, so the OLD `delay <= remaining`
        // rule would sleep and then re-send with ~0.5s — below `minimumAttemptBudget`, and so a
        // near-certain `.timeout`. The informative `.router(deadlineExceeded)` already in hand
        // — it names the key and the request id, and says the generation is still collectable
        // — is strictly better than that, so it is thrown without sleeping.
        let log = RequestLog()
        installStub(
            [
                Stub(
                    504,
                    headers: ["X-Comfy-Error-Type": "deadline_exceeded", "Retry-After": "1"],
                    body: #"{"error_type":"deadline_exceeded","detail":"still running"}"#
                ),
                Stub(200, body: Self.imageOutput)
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let started = Date()
        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"], timeout: 1.5)
        })
        let elapsed = Date().timeIntervalSince(started)

        let routerError = try #require(Self.routerError(from: thrown))
        #expect(routerError.errorType == .deadlineExceeded)
        #expect(routerError.retryAfter == 1)
        #expect(log.count == 1, "it re-sent into a budget too small to answer in")
        #expect(elapsed < 1, "threw after \(elapsed)s — it slept before giving up")
    }

    // MARK: - Responses the run contract does not declare

    @Test("the run route's task delegate refuses every redirect rather than following it")
    func the_redirect_delegate_refuses_every_hop() async throws {
        // Asserted against the delegate DIRECTLY, not through the stub. `TestURLProtocol` hands
        // a 3xx straight back to the caller without engaging `URLSession`'s redirect machinery,
        // so an end-to-end stub test passes whether or not the delegate is installed — it
        // cannot distinguish a refused redirect from a followed one, and would be a regression
        // test in name only.
        //
        // What is being pinned: `nil` to the completion handler, which is `URLSession`'s
        // "do not follow — hand me the 3xx instead". Following one would replay the body, the
        // `Idempotency-Key` and the credential to the hop target (307/308), or rewrite the POST
        // to a GET of the per-model CATALOG route whose 200 would then read as a finished run
        // (301/302/303).
        let delegate = RouterRedirectRefusal()
        let session = TestURLProtocol.makeStubSession()
        let task = session.dataTask(with: URL(string: Self.expectedURL)!)
        defer { task.cancel() }

        for status in [301, 302, 303, 307, 308] {
            let response = try #require(
                HTTPURLResponse(
                    url: URL(string: Self.expectedURL)!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://evil.example.test/v2/models/bfl/flux-2-pro"]
                )
            )
            let hop = URLRequest(url: URL(string: "https://evil.example.test/v2/models/bfl/flux-2-pro")!)

            let followed: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(
                    session,
                    task: task,
                    willPerformHTTPRedirection: response,
                    newRequest: hop
                ) { continuation.resume(returning: $0) }
            }

            #expect(followed == nil, "a \(status) would have been followed to \(hop.url?.host ?? "nil")")
        }
    }

    @Test("a 3xx that reaches the status handling is an error, never a finished run", arguments: [301, 302, 307, 308])
    func a_redirect_status_is_not_a_success(status: Int) async throws {
        // The second half of the redirect defence: even if a 3xx arrives at the response
        // handling (an intermediary, or a future session that does not carry the delegate), it
        // must not be read as a run result.
        let log = RequestLog()
        installStub(
            [
                Stub(
                    status,
                    headers: ["Location": "https://evil.example.test/v2/models/bfl/flux-2-pro"],
                    body: "{}"
                )
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let thrown = await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"], timeout: 5)
        }

        #expect(thrown != nil, "a \(status) was accepted as a successful run")
        #expect(log.count == 1)
        for entry in log.entries {
            #expect(
                entry.url?.host == "api.comfy.org",
                "the credential went to \(entry.url?.host ?? "nil")"
            )
        }
    }

    @Test("a 2xx the run contract does not declare is not reported as a finished run", arguments: [202, 204, 206])
    func undeclared_2xx_is_not_a_success(status: Int) async throws {
        // The run route is synchronous and declares exactly one success, `200`. A `202` in
        // particular means the generation is still pending — returning it as a `RouterRunResult`
        // with `.null` output would tell the caller a run finished when it had not.
        let log = RequestLog()
        installStub([Stub(status, body: "{}")], log: log)
        defer { TestURLProtocol.uninstall() }

        let thrown = await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"], timeout: 5)
        }

        let raised = try #require(thrown, "a \(status) was reported as a finished run")
        #expect(log.count == 1)

        // And it must not read as `.internalError` ("Router itself failed"), which is close to
        // the opposite of what a `202 Accepted` means — a caller whose handling for that bucket
        // is "report it and start over with a fresh key" would pay for the generation twice.
        let routerError = try #require(Self.routerError(from: raised))
        #expect(routerError.errorType == .unknown("comfy-sdk/undeclared_status_\(status)"))
        #expect(routerError.httpStatus == status)
    }

    @Test("a model ID segment past the contract's declared maximum is refused before any request")
    func an_overlong_model_id_segment_is_refused() async throws {
        // The charset is deliberately left to the server — it answers `404 model_not_found`
        // with suggestions, which is a better error than this can produce. Length is different:
        // an unbounded segment reaches the wire with the credential attached, and a megabyte of
        // "model ID" is a request nobody meant to send.
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let longProvider = String(repeating: "a", count: 65)   // declared maximum is 64
        let longModel = String(repeating: "b", count: 129)     // declared maximum is 128

        for id in ["\(longProvider)/flux-2-pro", "bfl/\(longModel)"] {
            let thrown = try #require(await capture {
                try await makeModels().run(id, input: ["prompt": "a cat"], timeout: 5)
            })
            #expect(Self.rejectionIdentifier(thrown) == RouterTransport.invalidModelIdReason)
        }

        // The boundary values themselves are still accepted — the cap is inclusive.
        #expect(throws: Never.self) {
            _ = try RouterTransport.parseModelId(
                "\(String(repeating: "a", count: 64))/\(String(repeating: "b", count: 128))"
            )
        }
        #expect(log.count == 0)
    }

    // MARK: - Error mapping through the transport

    @Test("a 422 FastAPI body surfaces .router with validationErrors parsed")
    func validation_errors_reach_the_caller() async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(
                    422,
                    headers: ["X-Comfy-Error-Type": "invalid_input"],
                    body: #"""
                    {"detail":[{"loc":["body","width"],"msg":"Input should be greater than 256","type":"greater_than","ctx":{"limit_value":256},"input":64}]}
                    """#
                )
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["width": 64])
        })
        let routerError = try #require(Self.routerError(from: thrown))
        #expect(routerError.errorType == .invalidInput)
        #expect(routerError.httpStatus == 422)
        #expect(routerError.validationErrors.count == 1)
        let detail = try #require(routerError.validationErrors.first)
        #expect(detail.location == "body.width")
        #expect(detail.type == "greater_than")
        #expect(detail.ctx?["limit_value"].intValue == 256)
        #expect(log.count == 1)
    }

    @Test("403 not_enabled surfaces .router(.notEnabled), NOT .authInvalid")
    func not_enabled_403_is_a_router_error_not_an_auth_failure() async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(
                    403,
                    headers: ["X-Comfy-Error-Type": "not_enabled"],
                    body: #"{"error_type":"not_enabled","detail":"Comfy Router is not enabled for this caller"}"#
                )
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"])
        })
        let routerError = try #require(Self.routerError(from: thrown))
        #expect(routerError.errorType == .notEnabled)
        #expect(routerError.httpStatus == 403)
        #expect(log.count == 1)
    }

    // MARK: - 401 refresh

    @Test("401 unauthorized in oauthRefreshable mode refreshes once and re-sends under the same key")
    func unauthorized_401_refreshes_once_and_reuses_the_key() async throws {
        let log = RequestLog()
        let refreshCount = Counter()
        let tokenBox = TokenBox("stale-access-token")

        TestURLProtocol.install { request in
            if request.url?.path == "/oauth/token" {
                refreshCount.increment()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                let body = #"{"access_token":"fresh-access-token","refresh_token":"new-refresh","expires_in":900}"#
                return (response, Data(body.utf8))
            }
            log.record(request)
            let isFresh = request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access-token"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: isFresh ? 200 : 401,
                httpVersion: "HTTP/1.1",
                headerFields: isFresh
                    ? ["Content-Type": "application/json"]
                    : ["Content-Type": "application/json", "X-Comfy-Error-Type": "unauthorized"]
            )!
            let body = isFresh ? Self.imageOutput : #"{"detail":"unauthorized"}"#
            return (response, Data(body.utf8))
        }
        defer { TestURLProtocol.uninstall() }

        let credential = ComfyCredential.oauthRefreshable(
            tokenProvider: { tokenBox.value },
            refreshProvider: { "current-refresh-token" },
            tokenStore: { tokenBox.set($0.accessToken) },
            // Far from expiry, so the ONLY refresh that can fire is the reactive 401 one.
            expiryProvider: { Date().addingTimeInterval(3600) }
        )
        let result = try await makeModels(credential: credential)
            .run(Self.modelId, input: ["prompt": "a cat"])

        #expect(refreshCount.value == 1)
        #expect(log.count == 2)
        let sent = log.entries
        #expect(sent[0].headers["Idempotency-Key"] == sent[1].headers["Idempotency-Key"])
        #expect(sent[0].headers["Idempotency-Key"] == result.idempotencyKey)
        #expect(sent[0].body == sent[1].body)
        #expect(result.output["images"][0]["url"].stringValue == "https://cdn.example.test/a.png")
    }

    @Test("401 in API-key mode surfaces .authInvalid with no retry")
    func unauthorized_401_in_api_key_mode_is_terminal() async throws {
        let log = RequestLog()
        installStub(
            [Stub(401, headers: ["X-Comfy-Error-Type": "unauthorized"], body: #"{"detail":"nope"}"#)],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"])
        })
        guard case ComfyError.authInvalid = try #require(thrown as? ComfyError) else {
            Issue.record("expected .authInvalid, got \(thrown)")
            return
        }
        #expect(log.count == 1)
    }

    @Test("a 401 naming another bucket stays a RouterError rather than triggering the refresh path")
    func non_unauthorized_401_stays_a_router_error() async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(
                    401,
                    headers: ["X-Comfy-Error-Type": "not_enabled"],
                    body: #"{"error_type":"not_enabled","detail":"not on the ramp"}"#
                )
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"])
        })
        let routerError = try #require(Self.routerError(from: thrown))
        #expect(routerError.errorType == .notEnabled)
        #expect(log.count == 1)
    }

    // MARK: - Model-ID validation

    @Test(
        "a malformed model ID throws before any request reaches the network",
        arguments: ["flux", "a/b/c", "a/..", "", "/", "bfl/", "/flux-2-pro", "a//b", "./b", "a/."]
    )
    func malformed_model_ids_throw_before_any_request(modelId: String) async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(modelId, input: ["prompt": "a cat"])
        })
        guard case ComfyError.serverRejected(let reason)? = thrown as? ComfyError,
              case .other(let identifier) = reason else {
            Issue.record("expected .serverRejected(.other), got \(thrown)")
            return
        }
        #expect(identifier.hasPrefix(RouterTransport.invalidModelIdReason))
        #expect(log.count == 0, "a malformed model ID reached the network")
    }

    @Test("the three-segment variant form is refused with its own identifier")
    func variant_model_id_names_the_variant_form() async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run("bfl/flux-2-pro/turbo", input: ["prompt": "a cat"])
        })
        guard case ComfyError.serverRejected(let reason)? = thrown as? ComfyError,
              case .other(let identifier) = reason else {
            Issue.record("expected .serverRejected(.other), got \(thrown)")
            return
        }
        #expect(identifier == RouterTransport.invalidModelIdVariantReason)
        #expect(log.count == 0)
    }

    @Test("a well-formed ID needing escaping is percent-encoded per segment, never across the separator")
    func model_id_segments_are_encoded_individually() throws {
        let path = try RouterTransport.parseModelId("bfl/flux 2?pro#x")
        #expect(path.provider == "bfl")
        #expect(path.model == "flux%202%3Fpro%23x")
        #expect(!path.model.contains("/"))
    }

    @Test("serialisation is key-order stable, so the same input re-sends identical bytes under one key")
    func serialisation_is_key_order_stable() throws {
        // Swift seeds `Dictionary` hashing PER PROCESS, so an unsorted `JSONSerialization` of
        // this dictionary emits a different key order in every run. The documented recovery
        // flow — persist the key, relaunch, `run(..., idempotencyKey:)` again — would then
        // present Router the same key with different bytes and be refused `409 invalid_input`
        // instead of served. `.sortedKeys` is what makes that flow work, so it is asserted
        // here rather than left as an implementation detail.
        let input: [String: Any] = [
            "prompt": "a cat",
            "width": 1024,
            "seed": 7,
            "steps": 30,
            "cfg": 3.5,
            "nested": ["z": 1, "a": 2]
        ]
        let bytes = try RouterTransport.serializeInput(input)
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(json == #"{"cfg":3.5,"nested":{"a":2,"z":1},"prompt":"a cat","seed":7,"steps":30,"width":1024}"#)

        // A second, independently-built equal dictionary must produce the same bytes.
        var rebuilt: [String: Any] = [:]
        for key in ["nested", "cfg", "steps", "seed", "width", "prompt"] {
            rebuilt[key] = input[key]
        }
        #expect(try RouterTransport.serializeInput(rebuilt) == bytes)
    }

    @Test("input that is not JSON-serialisable throws .unknown before any request")
    func non_serialisable_input_throws_unknown() async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["when": Date()])
        })
        guard case ComfyError.unknown = try #require(thrown as? ComfyError) else {
            Issue.record("expected .unknown, got \(thrown)")
            return
        }
        #expect(log.count == 0)
    }

    // MARK: - Cancellation

    @Test("cancelling during a collect sleep surfaces .cancelled and sends no third request")
    func cancellation_during_the_collect_sleep_surfaces_cancelled() async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(
                    504,
                    headers: ["X-Comfy-Error-Type": "deadline_exceeded", "Retry-After": "5"],
                    body: #"{"error_type":"deadline_exceeded","detail":"still running"}"#
                ),
                Stub(200, body: Self.imageOutput)
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let models = makeModels()
        let task = Task { try await models.run(Self.modelId, input: ["prompt": "a cat"], timeout: 60) }

        // Wait for the first request to land, so the cancel arrives inside the sleep rather
        // than before the run starts. Bounded: a `run` that throws before the stub records
        // anything never moves the counter, and an unbounded spin would hang this test rather
        // than fail it.
        var waited = 0
        while log.count < 1, waited < 400 {
            try await Task.sleep(nanoseconds: 5_000_000)
            waited += 1
        }
        try #require(log.count >= 1, "the first request never reached the stub")
        task.cancel()

        let thrown = try #require(await capture { try await task.value })
        guard case ComfyError.cancelled = try #require(thrown as? ComfyError) else {
            Issue.record("expected .cancelled, got \(thrown)")
            return
        }
        #expect(log.count == 1, "a request went out after cancellation")
    }

    // MARK: - Pre-flight validation

    /// The regression that matters most in this file.
    ///
    /// A NaN `timeout` used to make the collect loop UNBOUNDED: `Date().addingTimeInterval(.nan)`
    /// is a NaN deadline, and `Date`'s `<=` desugars to `!(rhs < lhs)`, which is `true` for
    /// NaN — so the loop's only bound passed on every pass and it re-sent billable requests
    /// until the task was cancelled. Both locks are asserted here: the public boundary refuses
    /// it, and the transport refuses it even when the boundary is bypassed.
    @Test("a non-finite timeout is refused before anything is sent, and never spins the collect loop")
    func non_finite_timeout_is_refused() async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"], timeout: .nan)
        })
        #expect(Self.rejectionIdentifier(thrown) == RouterTransport.invalidTimeoutReason)
        #expect(log.count == 0, "a NaN timeout reached the network")

        // Straight at the transport, bypassing `RouterModels.run`'s boundary check: the
        // transport must refuse a non-finite budget itself rather than build a deadline from
        // it. On the monotonic clock this is not belt-and-braces but load-bearing —
        // `Duration.seconds(.nan)` traps, where the old `Date` deadline merely went NaN and was
        // caught by the loop's `remaining > 0` guard. So the lock moved ahead of the deadline
        // rather than behind it, and this asserts it is still there.
        let session = TestURLProtocol.makeStubSession()
        let transport = RouterTransport(
            session: session,
            baseURL: RouterModels.defaultBaseURL,
            transport: Transport(
                session: session,
                baseURL: Self.cloudBaseURL,
                credential: .apiKey(Self.apiKey)
            )
        )
        let direct = try #require(await capture {
            try await transport.run(
                path: RouterTransport.parseModelId(Self.modelId),
                body: Data("{}".utf8),
                idempotencyKey: "11111111-1111-1111-1111-111111111111",
                timeout: .nan
            )
        })
        #expect(Self.rejectionIdentifier(direct) == RouterTransport.invalidTimeoutReason)
        #expect(log.count == 0, "a NaN deadline let a request out of the collect loop")
    }

    @Test("a non-positive timeout is refused before anything is sent", arguments: [0.0, -1.0])
    func non_positive_timeout_is_refused(timeout: TimeInterval) async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"], timeout: timeout)
        })
        #expect(Self.rejectionIdentifier(thrown) == RouterTransport.invalidTimeoutReason)
        #expect(log.count == 0)
    }

    /// An uncarriable key is refused here rather than becoming a blank or mangled header.
    ///
    /// The empty and whitespace cases are the ones with teeth: they send a header a server
    /// reads as ABSENT, so the at-most-once billing guarantee the caller asked for silently
    /// does not apply while `RouterRunResult.idempotencyKey` still reports what they passed.
    @Test(
        "an idempotency key the contract cannot carry is refused before anything is sent",
        arguments: ["", " ", "\t", "has space", "bad\r\nInjected: header", "ke\u{00FF}y",
                    String(repeating: "k", count: 256)]
    )
    func uncarriable_idempotency_keys_are_refused(key: String) async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"], idempotencyKey: key)
        })
        #expect(Self.rejectionIdentifier(thrown) == RouterTransport.invalidIdempotencyKeyReason)
        #expect(log.count == 0, "an uncarriable idempotency key reached the network")
    }

    @Test("a key at the contract's 255-character maximum is accepted and sent verbatim")
    func maximum_length_idempotency_key_is_accepted() async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let key = String(repeating: "k", count: 255)
        let result = try await makeModels().run(
            Self.modelId,
            input: ["prompt": "a cat"],
            idempotencyKey: key
        )
        #expect(result.idempotencyKey == key)
        #expect(log.entries.first?.headers["Idempotency-Key"] == key)
    }

    /// A base URL the SDK will not post a credential to.
    ///
    /// The query case is the one that does not fail loudly on its own: appending the route to
    /// `https://api.comfy.org/?x=1` re-parses into a POST to the HOST ROOT carrying the whole
    /// route in the query string — with the credential header attached — rather than a 404.
    @Test(
        "a base URL that is not plain https is refused before anything is sent",
        arguments: [
            "https://api.comfy.org/?x=1",
            "https://api.comfy.org/#frag",
            "http://api.comfy.org",
            "ftp://api.comfy.org",
            "https:///v2"
        ]
    )
    func unusable_base_urls_are_refused(base: String) async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let url = try #require(URL(string: base))
        let thrown = try #require(await capture {
            try await makeModels(baseURL: url).run(Self.modelId, input: ["prompt": "a cat"])
        })
        #expect(Self.rejectionIdentifier(thrown) == RouterTransport.invalidBaseURLReason)
        #expect(log.count == 0, "\(base) reached the network carrying the credential")
    }

    @Test("a timeout too short to answer in is refused before anything is sent", arguments: [0.5, 0.999])
    func a_sub_second_timeout_is_refused(timeout: TimeInterval) async throws {
        // The collect loop's floor cannot un-send a FIRST attempt the caller never had the
        // budget for, so the same floor is held at the boundary. Otherwise `timeout: 0.5` fires
        // one billable POST with a bound too short to answer in and reports a bare `.timeout` —
        // documented as an outcome that is unknown and, on a defaulted key, unrecoverable.
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"], timeout: timeout)
        })

        #expect(Self.rejectionIdentifier(thrown) == RouterTransport.invalidTimeoutReason)
        #expect(log.count == 0, "a sub-second budget still fired a billable request")
    }

    @Test("a timeout past the supported maximum is refused rather than trapping the clock")
    func an_enormous_timeout_is_refused() async throws {
        // `Duration.seconds(_:)` traps on a Double this large, where `Date.addingTimeInterval`
        // saturated — so the bound is what makes the monotonic deadline safe, not a policy.
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["prompt": "a cat"], timeout: 1e30)
        })

        #expect(Self.rejectionIdentifier(thrown) == RouterTransport.invalidTimeoutReason)
        #expect(log.count == 0)
    }

    @Test("the collect loop stops at the attempt cap even with budget to spare")
    func the_collect_loop_is_capped_in_requests() async throws {
        // The deadline bounds the call in time; this bounds it in REQUESTS. A host answering
        // `409 concurrency_limit_exceeded` with the contract's minimum `Retry-After: 1` would
        // otherwise drive hundreds of full POSTs inside one 660s budget, each re-uploading the
        // caller's entire input. The cap is injected here only so the test does not have to
        // sleep for the real 32 attempts.
        let log = RequestLog()
        installStub(
            [
                Stub(
                    409,
                    headers: ["X-Comfy-Error-Type": "concurrency_limit_exceeded", "Retry-After": "1"],
                    body: #"{"error_type":"concurrency_limit_exceeded","detail":"busy"}"#
                )
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        let session = TestURLProtocol.makeStubSession()
        let models = RouterModels(
            baseURL: RouterModels.defaultBaseURL,
            transport: RouterTransport(
                session: session,
                baseURL: RouterModels.defaultBaseURL,
                transport: Transport(
                    session: session,
                    baseURL: Self.cloudBaseURL,
                    credential: .apiKey(Self.apiKey)
                ),
                maximumAttempts: 3
            )
        )

        let thrown = try #require(await capture {
            try await models.run(Self.modelId, input: ["prompt": "a cat"], timeout: 60)
        })

        let routerError = try #require(Self.routerError(from: thrown))
        #expect(routerError.errorType == .concurrencyLimitExceeded)
        // Hitting the cap is not data loss: the key is still on the error, so the caller can
        // collect the generation by re-running under it.
        #expect(routerError.idempotencyKey.isEmpty == false)
        #expect(log.count == 3, "sent \(log.count) requests against a cap of 3")
    }

    @Test("a non-finite number in input throws instead of terminating the process", arguments: [
        Double.nan, .infinity, -.infinity
    ])
    func a_non_finite_number_in_input_is_refused(value: Double) async throws {
        // Pins the DOCUMENTED outcome — `.unknown(RouterInputSerializationError)`, nothing sent
        // — for the shape callers reach by accident: `a / b` with `b == 0`.
        //
        // Worth knowing what this does and does not prove. It passes with
        // `containsNonFiniteNumber` removed, because `isValidJSONObject` already rejects these
        // on the platforms this package targets (measured). The value here is the contract, not
        // which of the two guards delivers it: were Foundation ever to admit a non-finite
        // number, `data(withJSONObject:)` would raise an uncatchable `NSInvalidArgumentException`
        // and take the caller's process down, and this test would catch that change.
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: ["cfg": value], timeout: 5)
        })
        guard case .unknown(let underlying)? = thrown as? ComfyError else {
            Issue.record("expected .unknown, got \(thrown)")
            return
        }
        #expect(underlying is RouterInputSerializationError)
        #expect(log.count == 0)
    }

    @Test("a non-finite number nested inside input is refused too")
    func a_nested_non_finite_number_is_refused() async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let nested: [String: Any] = ["opts": ["scales": [1.0, Double.nan]]]
        let thrown = try #require(await capture {
            try await makeModels().run(Self.modelId, input: nested, timeout: 5)
        })
        #expect((thrown as? ComfyError).map { if case .unknown = $0 { true } else { false } } == true)
        #expect(log.count == 0)

        // A finite payload of the same shape still goes out — the guard is not over-broad.
        #expect(throws: Never.self) {
            _ = try RouterTransport.serializeInput(["opts": ["scales": [1.0, 2.5]]])
        }
    }

    @Test("the cap holds when the final permitted send is the one that 401s")
    func the_cap_holds_when_the_last_send_is_a_401() async throws {
        // The 401 branch throws `.authInvalid` BEFORE the collect guard, so a cap checked only
        // there is skipped entirely on that path: `withAuthRetry` refreshes, `collect` re-enters
        // and the deadline-only guard at the top fires send `maximumAttempts + 1`. The earlier
        // cap test cannot catch this because its 401 lands mid-sequence rather than on the
        // cap-th send.
        let log = RequestLog()
        let refreshCount = Counter()
        let tokenBox = TokenBox("stale-access-token")

        TestURLProtocol.install { request in
            if request.url?.path == "/oauth/token" {
                refreshCount.increment()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                let body = #"{"access_token":"fresh-access-token","refresh_token":"new-refresh","expires_in":900}"#
                return (response, Data(body.utf8))
            }
            log.record(request)
            // Sends 1 and 2 are collectable; send 3 — the cap-th — is the credential 401.
            if log.count >= 3 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json", "X-Comfy-Error-Type": "unauthorized"]
                )!
                return (response, Data(#"{"detail":"unauthorized"}"#.utf8))
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 409,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "X-Comfy-Error-Type": "concurrency_limit_exceeded",
                    "Retry-After": "1"
                ]
            )!
            return (response, Data(#"{"error_type":"concurrency_limit_exceeded","detail":"busy"}"#.utf8))
        }
        defer { TestURLProtocol.uninstall() }

        let credential = ComfyCredential.oauthRefreshable(
            tokenProvider: { tokenBox.value },
            refreshProvider: { "current-refresh-token" },
            tokenStore: { tokenBox.set($0.accessToken) },
            expiryProvider: { Date().addingTimeInterval(3600) }
        )
        let session = TestURLProtocol.makeStubSession()
        let models = RouterModels(
            baseURL: RouterModels.defaultBaseURL,
            transport: RouterTransport(
                session: session,
                baseURL: RouterModels.defaultBaseURL,
                transport: Transport(
                    session: session,
                    baseURL: Self.cloudBaseURL,
                    credential: credential
                ),
                maximumAttempts: 3
            )
        )

        let thrown = try #require(await capture {
            try await models.run(Self.modelId, input: ["prompt": "a cat"], timeout: 60)
        })

        #expect(log.count == 3, "sent \(log.count) requests against a cap of 3")
        // And the run reports the key-bearing RouterError from the last answered send rather
        // than a bare `.authInvalid` or `.timeout`, so the generation stays collectable.
        let routerError = try #require(Self.routerError(from: thrown))
        #expect(routerError.errorType == .concurrencyLimitExceeded)
        #expect(routerError.idempotencyKey.isEmpty == false)
    }

    @Test("the attempt cap is a per-run budget, not a per-collect one, so a 401 does not double it")
    func the_attempt_cap_survives_the_auth_retry() async throws {
        // `withAuthRetry` re-runs the whole `collect` closure after a 401 refresh. A counter
        // local to `collect` restarts at zero there, so one `run` could spend the whole cap,
        // take a 401, and spend it again — 2x the documented ceiling, each send re-uploading
        // the caller's entire input. The counter therefore lives at `run` scope.
        //
        // Script: collectable 409s until the 401 lands, then collectable 409s forever. With a
        // cap of 3 the run must stop at 3 SENDS in total, not 3 before and 3 after.
        let log = RequestLog()
        let refreshCount = Counter()
        let tokenBox = TokenBox("stale-access-token")

        TestURLProtocol.install { request in
            if request.url?.path == "/oauth/token" {
                refreshCount.increment()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                let body = #"{"access_token":"fresh-access-token","refresh_token":"new-refresh","expires_in":900}"#
                return (response, Data(body.utf8))
            }
            log.record(request)
            // The SECOND run request 401s, which is what re-enters `collect`. Everything else
            // is a collectable 409 the loop would happily keep re-sending.
            if log.count == 2 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json", "X-Comfy-Error-Type": "unauthorized"]
                )!
                return (response, Data(#"{"detail":"unauthorized"}"#.utf8))
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 409,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "X-Comfy-Error-Type": "concurrency_limit_exceeded",
                    "Retry-After": "1"
                ]
            )!
            return (response, Data(#"{"error_type":"concurrency_limit_exceeded","detail":"busy"}"#.utf8))
        }
        defer { TestURLProtocol.uninstall() }

        let credential = ComfyCredential.oauthRefreshable(
            tokenProvider: { tokenBox.value },
            refreshProvider: { "current-refresh-token" },
            tokenStore: { tokenBox.set($0.accessToken) },
            expiryProvider: { Date().addingTimeInterval(3600) }
        )
        let session = TestURLProtocol.makeStubSession()
        let models = RouterModels(
            baseURL: RouterModels.defaultBaseURL,
            transport: RouterTransport(
                session: session,
                baseURL: RouterModels.defaultBaseURL,
                transport: Transport(
                    session: session,
                    baseURL: Self.cloudBaseURL,
                    credential: credential
                ),
                maximumAttempts: 3
            )
        )

        let thrown = try #require(await capture {
            try await models.run(Self.modelId, input: ["prompt": "a cat"], timeout: 60)
        })

        #expect(refreshCount.value == 1, "the 401 refresh did not fire, so the re-entry was never exercised")
        #expect(Self.routerError(from: thrown)?.errorType == .concurrencyLimitExceeded)
        #expect(log.count == 3, "sent \(log.count) run requests against a per-run cap of 3")
    }

    @Test("a base URL smuggling the real host into userinfo is refused", arguments: [
        "https://api.comfy.org@evil.test",
        "https://api.comfy.org:token@evil.test",
        "https://user@api.comfy.org"
    ])
    func a_base_url_carrying_userinfo_is_refused(base: String) async throws {
        // `https://api.comfy.org@evil.test` parses as user `api.comfy.org`, host `evil.test` —
        // so it clears the scheme/host/query/fragment checks while READING as the real Router
        // host to anyone auditing the configured string. Every run would then post the body,
        // the `Idempotency-Key` and the credential to `evil.test`.
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let models = makeModels(baseURL: URL(string: base)!)
        let thrown = try #require(await capture {
            try await models.run(Self.modelId, input: ["prompt": "a cat"], timeout: 5)
        })

        #expect(Self.rejectionIdentifier(thrown) == RouterTransport.invalidBaseURLReason)
        #expect(log.count == 0, "the credential went out to \(log.entries.first?.url?.host ?? "nil")")
    }

    @Test("the per-attempt bound is sampled after applyAuth, so a slow refresh cannot outlive the budget")
    func the_send_budget_is_sampled_after_apply_auth() async throws {
        // `applyAuth` is not free: in `.oauth` mode it awaits a caller-supplied `tokenProvider`
        // closure, an unbounded round trip this deadline does not cover. Sampling the remainder
        // BEFORE that await would stamp the request with a bound generated before an unbounded
        // wait — so a refresh slower than the budget would still fire a billable POST past the
        // caller's wall-clock deadline, carrying an over-generous idle timeout.
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        // A token provider that burns the whole budget before the request is built.
        let credential = ComfyCredential.oauth(tokenProvider: {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return Self.bearerToken
        })

        let thrown = try #require(await capture {
            try await makeModels(credential: credential)
                .run(Self.modelId, input: ["prompt": "a cat"], timeout: 1)
        })

        guard case .timeout? = thrown as? ComfyError else {
            Issue.record("expected .timeout, got \(thrown)")
            return
        }
        #expect(log.count == 0, "a billable POST went out after the budget had already passed")
    }

    @Test("a base URL carrying a path prefix keeps it, with the route appended once")
    func base_url_path_prefix_is_preserved() async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let models = makeModels(baseURL: try #require(URL(string: "https://router.staging.test/edge/")))
        _ = try await models.run(Self.modelId, input: ["prompt": "a cat"])

        #expect(
            log.entries.first?.url?.absoluteString
                == "https://router.staging.test/edge/v2/models/bfl/flux-2-pro"
        )
    }

    // MARK: - Deadline

    /// `timeout` bounds the WHOLE call, so a re-send inherits the remainder.
    ///
    /// Before this, every attempt was handed a fresh copy of `timeout`, which made the
    /// documented wall-clock bound a per-attempt bound instead.
    @Test("a re-send inherits what is left of the budget rather than a fresh copy of it")
    func resend_inherits_the_remaining_budget() async throws {
        let log = RequestLog()
        installStub(
            [
                Stub(
                    504,
                    headers: ["X-Comfy-Error-Type": "deadline_exceeded", "Retry-After": "1"],
                    body: #"{"error_type":"deadline_exceeded","detail":"still running"}"#
                ),
                Stub(200, body: Self.imageOutput)
            ],
            log: log
        )
        defer { TestURLProtocol.uninstall() }

        _ = try await makeModels().run(Self.modelId, input: ["prompt": "a cat"], timeout: 30)

        #expect(log.count == 2)
        let sent = log.entries
        #expect(sent[0].timeoutInterval <= 30)
        #expect(
            sent[1].timeoutInterval < sent[0].timeoutInterval - 0.9,
            "the re-send restarted the clock instead of inheriting the remainder"
        )
    }

    // MARK: - Client wiring

    @Test("ComfyCloudClient exposes models on the contract's default host")
    func client_exposes_models_on_the_default_host() {
        let client = ComfyCloudClient(apiKey: "irrelevant")
        #expect(client.models.baseURL == RouterModels.defaultBaseURL)
        #expect(RouterModels.defaultBaseURL.absoluteString == "https://api.comfy.org")
        #expect(RouterModels.defaultBaseURL == RouterConstants.defaultBaseURL)
    }

    @Test("routerBaseURL redirects the Router surface without touching the workflow surface")
    func router_base_url_override_is_honoured() {
        let staging = URL(string: "https://router.staging.test")!
        let client = ComfyCloudClient(credential: .apiKey("irrelevant"), routerBaseURL: staging)
        #expect(client.models.baseURL == staging)
    }

    @Test("a base URL with a trailing slash resolves to the same route, not a doubled separator")
    func trailing_slash_base_url_does_not_double_the_separator() async throws {
        let log = RequestLog()
        installStub([Stub(200, body: Self.imageOutput)], log: log)
        defer { TestURLProtocol.uninstall() }

        let models = makeModels(baseURL: URL(string: "https://router.staging.test/")!)
        _ = try await models.run(Self.modelId, input: ["prompt": "a cat"])

        #expect(
            log.entries.first?.url?.absoluteString
                == "https://router.staging.test/v2/models/bfl/flux-2-pro"
        )
    }

    // MARK: - Helpers

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.lock(); defer { lock.unlock() }; _value += 1 }
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    }

    private final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String
        init(_ initial: String) { _value = initial }
        var value: String { lock.lock(); defer { lock.unlock() }; return _value }
        func set(_ new: String) { lock.lock(); defer { lock.unlock() }; _value = new }
    }

    /// Runs `body` and returns the error it threw, or `nil` if it succeeded.
    ///
    /// `#expect(throws:)` cannot hand back the thrown value, and every error assertion in this
    /// file needs to read fields off it (`errorType`, `retryAfter`, the rejection identifier).
    private func capture<T>(_ body: () async throws -> T) async -> (any Error)? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error
        }
    }
}
