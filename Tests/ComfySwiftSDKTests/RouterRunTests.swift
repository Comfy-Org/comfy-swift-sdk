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

    private static func routerError(from error: any Error) -> RouterError? {
        guard case .router(let routerError)? = error as? ComfyError else { return nil }
        return routerError
    }

    // MARK: - Happy path

    @Test("happy path: canonical URL, POST, JSON headers, a minted lowercase-UUID key, the 660s timeout, and the parsed output")
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
        #expect(sent.timeoutInterval == RouterModels.defaultTimeout)
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

    /// The three status/bucket pairings the contract says a same-key re-send collects.
    /// `Retry-After: 1` is the contract's minimum — see the note at the top of this file.
    @Test(
        "collect loop re-sends the same key and the same bytes",
        arguments: [
            (504, "deadline_exceeded"),
            (409, "concurrency_limit_exceeded"),
            (429, "rate_limited")
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
        // than before the run starts.
        while log.count < 1 { try await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()

        let thrown = try #require(await capture { try await task.value })
        guard case ComfyError.cancelled = try #require(thrown as? ComfyError) else {
            Issue.record("expected .cancelled, got \(thrown)")
            return
        }
        #expect(log.count == 1, "a request went out after cancellation")
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
