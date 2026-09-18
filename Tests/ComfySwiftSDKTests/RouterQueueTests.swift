//
//  RouterQueueTests.swift
//  ComfySwiftSDKTests
//
//  `client.models.submit` / `subscribe` / `handle` — Comfy Router's queued delivery mode —
//  against the `TestURLProtocol` stub, in the style `RouterRunTests` set.
//
//  Two things worth knowing before reading the polling tests:
//
//  * The poll schedule is real time. `RouterTransport.pollInitialDelay` is 0.5 s and the
//    backoff factor is 1.5, so a three-poll test spends ~1.25 s asleep. That is the schedule
//    under test, not incidental slowness — the tests that can assert against one poll do.
//  * Request *routes and counts* are the assertions that matter. "One submit, N status polls,
//    one result fetch, and no cancel" is what distinguishes queued delivery working from the
//    SDK quietly falling back to something else.
//

import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("RouterQueue — submit / subscribe / handle over the Comfy Router queue", .serialized)
struct RouterQueueTests {

    // MARK: - Recording stub

    /// Every request the stub saw, in order, with its body already drained.
    private final class RequestLog: @unchecked Sendable {
        struct Entry {
            let url: URL?
            let method: String?
            let headers: [String: String]
            let body: Data?
        }

        private let lock = NSLock()
        private var _entries: [Entry] = []

        func record(_ request: URLRequest) {
            let entry = Entry(
                url: request.url,
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.drainBody(request)
            )
            lock.lock(); defer { lock.unlock() }
            _entries.append(entry)
        }

        var entries: [Entry] { lock.lock(); defer { lock.unlock() }; return _entries }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _entries.count }

        /// Requests whose path ends in `suffix`, in order.
        func matching(_ suffix: String) -> [Entry] {
            entries.filter { $0.url?.path.hasSuffix(suffix) == true }
        }

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

    /// Routes each request to a stub by `(method, path suffix)` — the queue surface makes four
    /// different calls against one host, so a positional script would be unreadable.
    ///
    /// `status` is matched before the bare result route because the result path is a prefix of
    /// the status path.
    private struct Routes {
        var submit: [Stub] = [Stub(201, body: #"{"request_id":"req-1","status":"IN_QUEUE"}"#)]
        var status: [Stub] = [Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED"}"#)]
        var result: [Stub] = [Stub(200, body: #"{"images":[{"url":"https://cdn.example.test/a.png"}]}"#)]
        var cancel: [Stub] = [Stub(202, body: #"{"status":"CANCELLATION_REQUESTED"}"#)]
    }

    /// Installs a route-dispatching stub. Each route's last entry repeats if more requests
    /// arrive than were scripted, so an over-sending test fails on its count assertion with the
    /// extra requests visible rather than on an opaque `badURL`.
    private func installStub(_ routes: Routes, log: RequestLog) {
        TestURLProtocol.install { request in
            log.record(request)
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? ""

            let scripted: [Stub]
            let index: Int
            if method == "POST", path.hasSuffix("/requests") {
                scripted = routes.submit
                index = log.matching("/requests").count - 1
            } else if path.hasSuffix("/status") {
                scripted = routes.status
                index = log.matching("/status").count - 1
            } else if path.hasSuffix("/cancel") {
                scripted = routes.cancel
                index = log.matching("/cancel").count - 1
            } else {
                scripted = routes.result
                index = log.matching("/requests/req-1").filter {
                    $0.url?.path.hasSuffix("/status") == false
                        && $0.url?.path.hasSuffix("/cancel") == false
                }.count - 1
            }

            let stub = scripted[min(max(index, 0), scripted.count - 1)]
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

    private static let apiKey = "router-queue-test-api-key"
    private static let cloudBaseURL = URL(string: "https://cloud.comfy.org")!
    private static let modelId = "bfl/flux-2-pro"
    private static let submitURL = "https://api.comfy.org/v2/models/bfl/flux-2-pro/requests"
    private static let statusURL = "https://api.comfy.org/v2/models/bfl/flux-2-pro/requests/req-1/status"
    private static let resultURL = "https://api.comfy.org/v2/models/bfl/flux-2-pro/requests/req-1"
    private static let cancelURL = "https://api.comfy.org/v2/models/bfl/flux-2-pro/requests/req-1/cancel"

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

    private static func rejectionIdentifier(_ error: any Error) -> String? {
        guard case .serverRejected(let reason)? = error as? ComfyError,
              case .other(let identifier) = reason else { return nil }
        return identifier
    }

    private static func routerError(from error: any Error) -> RouterError? {
        guard case .router(let routerError)? = error as? ComfyError else { return nil }
        return routerError
    }

    /// `ComfyError` is not `Equatable` — it carries `Error` payloads — so the terminal cases
    /// are matched by pattern, naming what arrived instead when they do not.
    private static func expectTimeout(_ error: any Error, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .timeout? = error as? ComfyError else {
            Issue.record("expected ComfyError.timeout, got \(error)", sourceLocation: sourceLocation)
            return
        }
    }

    private static func expectCancelled(_ error: any Error, sourceLocation: SourceLocation = #_sourceLocation) {
        guard case .cancelled? = error as? ComfyError else {
            Issue.record("expected ComfyError.cancelled, got \(error)", sourceLocation: sourceLocation)
            return
        }
    }

    // MARK: - submit

    @Test("submit posts to …/requests with JSON headers, a minted lowercase-UUID key, and hands back the ids")
    func submit_composes_the_contract_request_and_reads_the_acknowledgement() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.submit = [
            Stub(201, body: #"{"request_id":"req-1","status":"IN_QUEUE","queue_position":4}"#)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let handle = try await makeModels().submit(Self.modelId, input: ["prompt": "a cat"])

        #expect(log.count == 1)
        let sent = try #require(log.entries.first)
        #expect(sent.url?.absoluteString == Self.submitURL)
        #expect(sent.method == "POST")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.headers["Accept"] == "application/json")
        #expect(sent.headers["X-API-Key"] == Self.apiKey)

        let key = try #require(sent.headers["Idempotency-Key"])
        #expect(UUID(uuidString: key) != nil)
        #expect(key == key.lowercased())
        #expect(handle.idempotencyKey == key)

        #expect(handle.requestId == "req-1")
        #expect(handle.model == Self.modelId)
        #expect(handle.queuePosition == 4)
    }

    @Test("submit: an explicit idempotencyKey overrides the minted one")
    func submit_honours_a_supplied_idempotency_key() async throws {
        let log = RequestLog()
        installStub(Routes(), log: log)
        defer { TestURLProtocol.uninstall() }

        let supplied = "my-own-queue-key-1"
        let handle = try await makeModels().submit(
            Self.modelId,
            input: ["prompt": "a cat"],
            idempotencyKey: supplied
        )

        #expect(log.entries.first?.headers["Idempotency-Key"] == supplied)
        #expect(handle.idempotencyKey == supplied)
    }

    @Test("submit: a collect re-send reuses the SAME key and the same body bytes")
    func submit_reuses_one_key_across_its_own_retries() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.submit = [
            Stub(
                409,
                headers: ["X-Comfy-Error-Type": "concurrency_limit_exceeded", "Retry-After": "1"],
                body: #"{"error_type":"concurrency_limit_exceeded","detail":"in flight"}"#
            ),
            Stub(201, body: #"{"request_id":"req-1","status":"IN_QUEUE"}"#)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let handle = try await makeModels().submit(
            Self.modelId,
            input: ["prompt": "a cat"],
            timeout: 30
        )

        let sent = log.entries
        #expect(sent.count == 2)
        #expect(sent[0].headers["Idempotency-Key"] == sent[1].headers["Idempotency-Key"])
        #expect(sent[0].body == sent[1].body)
        #expect(handle.idempotencyKey == sent[0].headers["Idempotency-Key"])
    }

    @Test("submit: 403 not_enabled throws .notEnabled and is NOT retried")
    func submit_does_not_retry_the_server_side_preview_gate() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.submit = [
            Stub(
                403,
                headers: ["X-Comfy-Error-Type": "not_enabled", "Retry-After": "1"],
                body: #"{"error_type":"not_enabled","detail":"Comfy Router queueing is not enabled."}"#
            )
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        await #expect(throws: ComfyError.self) {
            _ = try await makeModels().submit(Self.modelId, input: ["prompt": "a cat"], timeout: 30)
        }

        do {
            _ = try await makeModels().submit(Self.modelId, input: ["prompt": "a cat"], timeout: 30)
            Issue.record("expected a throw")
        } catch {
            let routerError = try #require(Self.routerError(from: error))
            #expect(routerError.errorType == .notEnabled)
            #expect(routerError.httpStatus == 403)
        }
        // Two calls above, one send each: the `Retry-After` on a bucket the contract does not
        // declare collectable must not buy a second billable submit.
        #expect(log.count == 2)
    }

    @Test("submit: a 201 whose body is not a JSON object throws an invalid-response error")
    func submit_refuses_a_malformed_acknowledgement() async throws {
        for body in ["[]", "\"req-1\"", "not json at all", ""] {
            let log = RequestLog()
            var routes = Routes()
            routes.submit = [Stub(201, body: body)]
            installStub(routes, log: log)

            do {
                _ = try await makeModels().submit(Self.modelId, input: ["prompt": "a cat"])
                Issue.record("expected a throw for body \(body)")
            } catch {
                guard case .unknown(let underlying)? = error as? ComfyError,
                      let invalid = underlying as? RouterInvalidResponseError else {
                    Issue.record("expected RouterInvalidResponseError for body \(body), got \(error)")
                    TestURLProtocol.uninstall()
                    continue
                }
                #expect(invalid.route == "submit")
            }
            TestURLProtocol.uninstall()
        }
    }

    @Test("submit: a server-sent request_id that is not one path segment is refused before it reaches a URL")
    func submit_validates_the_servers_own_request_id() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.submit = [Stub(201, body: #"{"request_id":"../../v2/models","status":"IN_QUEUE"}"#)]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeModels().submit(Self.modelId, input: ["prompt": "a cat"])
            Issue.record("expected a throw")
        } catch {
            #expect(Self.rejectionIdentifier(error) == "invalid_request_id")
        }
    }

    @Test("submit: 200, 201 and 202 are all an acceptance — what proves one is the request_id")
    func submit_accepts_the_three_acceptance_statuses() async throws {
        for status in [200, 201, 202] {
            var routes = Routes()
            routes.submit = [Stub(status, body: #"{"request_id":"req-1","status":"IN_QUEUE"}"#)]
            installStub(routes, log: RequestLog())
            let handle = try await makeModels().submit(Self.modelId, input: ["prompt": "a cat"])
            #expect(handle.requestId == "req-1")
            TestURLProtocol.uninstall()
        }

        // A 2xx carrying no id is still not an acceptance — a handle addressing nothing is
        // worse than a throw.
        var routes = Routes()
        routes.submit = [Stub(201, body: #"{"status":"IN_QUEUE"}"#)]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }
        do {
            _ = try await makeModels().submit(Self.modelId, input: ["prompt": "a cat"])
            Issue.record("expected a throw")
        } catch {
            guard case .unknown(let underlying)? = error as? ComfyError,
                  underlying is RouterInvalidResponseError else {
                Issue.record("expected RouterInvalidResponseError, got \(error)")
                return
            }
        }
    }

    @Test("submit: a 204 is not an acceptance")
    func submit_refuses_an_undeclared_success_status() async throws {
        var routes = Routes()
        routes.submit = [Stub(204, body: "")]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeModels().submit(Self.modelId, input: ["prompt": "a cat"])
            Issue.record("expected a throw")
        } catch {
            let routerError = try #require(Self.routerError(from: error))
            #expect(routerError.httpStatus == 204)
        }
    }

    // MARK: - handle(_:requestId:)

    @Test("handle(_:requestId:) rebuilds a handle with NO request made")
    func handle_makes_no_request() throws {
        let log = RequestLog()
        installStub(Routes(), log: log)
        defer { TestURLProtocol.uninstall() }

        let handle = try makeModels().handle(Self.modelId, requestId: "req-1")

        #expect(log.count == 0)
        #expect(handle.requestId == "req-1")
        #expect(handle.model == Self.modelId)
        #expect(handle.idempotencyKey == nil)
        #expect(handle.queuePosition == nil)
    }

    @Test("handle(_:requestId:) validates both ids locally, before the wire")
    func handle_validates_both_ids() throws {
        let log = RequestLog()
        installStub(Routes(), log: log)
        defer { TestURLProtocol.uninstall() }
        let models = makeModels()

        let badRequestIds = [
            "",                                    // empty
            "..",                                  // traversal
            ".",                                   // traversal
            "a/b",                                 // two segments, would re-shape the route
            "req 1",                               // space — not a header/path token
            "req\u{0}1",                           // control character
            String(repeating: "r", count: 257)     // past the 256-scalar bound
        ]
        for requestId in badRequestIds {
            do {
                _ = try models.handle(Self.modelId, requestId: requestId)
                Issue.record("expected a throw for request id \(requestId.debugDescription)")
            } catch {
                #expect(Self.rejectionIdentifier(error) == "invalid_request_id")
            }
        }

        // Exactly at the bound is fine; the model ID is validated by the same rules `run` uses.
        #expect(throws: Never.self) {
            _ = try models.handle(Self.modelId, requestId: String(repeating: "r", count: 256))
        }
        do {
            _ = try models.handle("bfl", requestId: "req-1")
            Issue.record("expected a throw")
        } catch {
            #expect(Self.rejectionIdentifier(error) == "invalid_model_id")
        }

        #expect(log.count == 0)
    }

    // MARK: - status

    @Test("status: GETs …/status and reads state, queue position, error_type and a capped Retry-After")
    func status_reads_the_contract_body() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [
            Stub(
                200,
                headers: ["Retry-After": "900"],
                body: #"{"request_id":"req-1","status":"IN_QUEUE","queue_position":7}"#
            )
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let status = try await makeModels().handle(Self.modelId, requestId: "req-1").status()

        let sent = try #require(log.entries.first)
        #expect(sent.url?.absoluteString == Self.statusURL)
        #expect(sent.method == "GET")
        #expect(sent.headers["Idempotency-Key"] == nil)
        #expect(status.state == .inQueue)
        #expect(status.queuePosition == 7)
        #expect(status.errorType == nil)
        // Server said 900 s; the queue caps a hint at 60 BEFORE anyone sleeps on it.
        #expect(status.retryAfter == RouterRequestHandle.maximumRetryAfter)
    }

    @Test("status: an unrecognised state decodes as .unknown and is NOT terminal")
    func status_treats_an_unknown_state_as_non_terminal() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [Stub(200, body: #"{"request_id":"req-1","status":"RECONCILING"}"#)]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let status = try await makeModels().handle(Self.modelId, requestId: "req-1").status()
        #expect(status.state == .unknown("RECONCILING"))
        #expect(status.state.isTerminal == false)
    }

    @Test("status: a body that is not a JSON object, or carries no status, throws an invalid-response error")
    func status_refuses_a_malformed_body() async throws {
        for body in ["[]", "{}", "\"IN_QUEUE\"", ""] {
            var routes = Routes()
            routes.status = [Stub(200, body: body)]
            installStub(routes, log: RequestLog())

            do {
                _ = try await makeModels().handle(Self.modelId, requestId: "req-1").status()
                Issue.record("expected a throw for body \(body)")
            } catch {
                guard case .unknown(let underlying)? = error as? ComfyError,
                      let invalid = underlying as? RouterInvalidResponseError else {
                    Issue.record("expected RouterInvalidResponseError for body \(body), got \(error)")
                    TestURLProtocol.uninstall()
                    continue
                }
                #expect(invalid.route == "status")
            }
            TestURLProtocol.uninstall()
        }
    }

    @Test("status: a COMPLETED carrying an error_type is reported, not thrown — reading a status is how you discover a failure")
    func status_reports_a_completion_failure_rather_than_throwing() async throws {
        var routes = Routes()
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED","error_type":"content_policy_violation"}"#)
        ]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        let status = try await makeModels().handle(Self.modelId, requestId: "req-1").status()
        #expect(status.state == .completed)
        #expect(status.errorType == .contentPolicyViolation)
    }

    @Test("status: an SDK-reserved bucket is not repeated — but the failure it reports is not discarded with the name")
    func status_refuses_a_reserved_error_type() async throws {
        var routes = Routes()
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED","error_type":"comfy-sdk/undeclared_status_418"}"#)
        ]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        let status = try await makeModels().handle(Self.modelId, requestId: "req-1").status()
        // Refusing the NAME and reporting no failure at all are different things. A collector
        // reads "this completion failed" from nothing but `errorType != nil`, so dropping this
        // to `nil` would make a `COMPLETED` carrying `comfy-sdk/…` read as a clean success.
        #expect(status.errorType == .internalError)
    }

    @Test("status: an error_type that is present but not a string still fails a collect")
    func status_synthesises_a_bucket_for_an_unusable_error_type() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED","error_type":418}"#)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeModels().handle(Self.modelId, requestId: "req-1").result()
            Issue.record("expected a throw")
        } catch {
            let routerError = try #require(Self.routerError(from: error))
            #expect(routerError.errorType == .internalError)
        }
        // Never collected: a completion that reported a failure is not a finished generation,
        // whatever shape the server put the report in.
        let resultFetches = log.entries.filter { $0.url?.absoluteString == Self.resultURL }
        #expect(resultFetches.isEmpty)
    }

    @Test("status: an absent error_type still reports no failure")
    func status_reports_no_failure_when_no_error_type_is_named() async throws {
        var routes = Routes()
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED","error_type":null}"#)
        ]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        let status = try await makeModels().handle(Self.modelId, requestId: "req-1").status()
        #expect(status.errorType == nil)
    }

    @Test("status: an oversized unrecognised state is capped before it is retained")
    func status_caps_a_response_controlled_state() async throws {
        let huge = String(repeating: "Z", count: 4096)
        var routes = Routes()
        routes.status = [Stub(200, body: #"{"request_id":"req-1","status":"\#(huge)"}"#)]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        let status = try await makeModels().handle(Self.modelId, requestId: "req-1").status()
        #expect(status.state.rawValue.unicodeScalars.count == 128)
        #expect(status.state.isTerminal == false)
    }

    // MARK: - result

    @Test("result polls to completion, then GETs …/requests/{id} for the provider's native output")
    func result_returns_the_native_output() async throws {
        let log = RequestLog()
        installStub(Routes(), log: log)
        defer { TestURLProtocol.uninstall() }

        let handle = try makeModels().handle(Self.modelId, requestId: "req-1")
        let result = try await handle.result()

        // The poll is authoritative and comes first; the fetch only happens once it says
        // COMPLETED. Same shape as the Python and TypeScript SDKs' `handle.get()`.
        #expect(log.matching("/status").count == 1)
        let sent = try #require(log.entries.last)
        #expect(sent.url?.absoluteString == Self.resultURL)
        #expect(sent.method == "GET")
        #expect(result.output["images"][0]["url"].stringValue == "https://cdn.example.test/a.png")
        // No submit was made through this handle, so there is no key to report — and an
        // invented one would be worse than none, because the documented flow is to re-send it.
        #expect(result.idempotencyKey == nil)
    }

    @Test("result: a body that is not a JSON object is returned unchanged, exactly as run does")
    func result_passes_a_non_object_body_through() async throws {
        var routes = Routes()
        routes.result = [Stub(200, body: "[1,2,3]")]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        let result = try await makeModels().handle(Self.modelId, requestId: "req-1").result()
        #expect(result.data == Data("[1,2,3]".utf8))
        #expect(result.output.arrayValue?.count == 3)
    }

    @Test("result: a 202 from the result route — the poll and the result disagreeing — is not an empty success")
    func result_refuses_to_report_an_unfinished_request_as_finished() async throws {
        var routes = Routes()
        routes.result = [Stub(202, body: #"{"request_id":"req-1","status":"IN_PROGRESS"}"#)]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeModels().handle(Self.modelId, requestId: "req-1").result()
            Issue.record("expected a throw")
        } catch {
            let routerError = try #require(Self.routerError(from: error))
            #expect(routerError.httpStatus == 202)
        }
    }

    @Test("result: a COMPLETED carrying an error_type throws the bucket — a collector never gets a failure as a result")
    func result_throws_a_reported_completion_failure() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED","error_type":"content_policy_violation"}"#)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeModels().handle(Self.modelId, requestId: "req-1").result()
            Issue.record("expected a throw")
        } catch {
            let routerError = try #require(Self.routerError(from: error))
            #expect(routerError.errorType == .contentPolicyViolation)
        }
        let resultFetches = log.entries.filter { $0.url?.absoluteString == Self.resultURL }
        #expect(resultFetches.isEmpty)
    }

    @Test("result: timeout 0 reads 'look once' — and an unfinished request then times out WITHOUT a cancel")
    func result_timeout_zero_looks_once_and_never_cancels() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [Stub(200, body: #"{"request_id":"req-1","status":"IN_PROGRESS"}"#)]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeModels().handle(Self.modelId, requestId: "req-1").result(timeout: 0)
            Issue.record("expected a throw")
        } catch {
            Self.expectTimeout(error)
        }
        #expect(log.matching("/status").count == 1)
        // A handle did not submit this request and does not own it: only `subscribe` cancels.
        #expect(log.matching("/cancel").isEmpty)
    }

    // MARK: - cancel

    @Test("cancel is sent as PUT and reports the contract's two outcomes without throwing")
    func cancel_uses_put_and_reports_both_outcomes() async throws {
        let log = RequestLog()
        installStub(Routes(), log: log)

        let handle = try makeModels().handle(Self.modelId, requestId: "req-1")
        let requested = try await handle.cancel()
        #expect(requested == .cancellationRequested)

        let sent = try #require(log.entries.first)
        #expect(sent.url?.absoluteString == Self.cancelURL)
        #expect(sent.method == "PUT")
        TestURLProtocol.uninstall()

        var routes = Routes()
        routes.cancel = [Stub(400, body: #"{"status":"ALREADY_COMPLETED"}"#)]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }
        let already = try await handle.cancel()
        #expect(already == .alreadyCompleted)
    }

    @Test("cancel: a 400 the contract does not name is still an error")
    func cancel_does_not_swallow_an_ordinary_refusal() async throws {
        var routes = Routes()
        routes.cancel = [
            Stub(
                400,
                headers: ["X-Comfy-Error-Type": "invalid_input"],
                body: #"{"error_type":"invalid_input","detail":"no such request"}"#
            )
        ]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeModels().handle(Self.modelId, requestId: "req-1").cancel()
            Issue.record("expected a throw")
        } catch {
            let routerError = try #require(Self.routerError(from: error))
            #expect(routerError.errorType == .invalidInput)
        }
    }

    // MARK: - events

    @Test("events yields queued → inProgress → completed, collapsing consecutive identical observations")
    func events_reports_each_change_once() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"IN_QUEUE","queue_position":2}"#),
            Stub(200, body: #"{"request_id":"req-1","status":"IN_QUEUE","queue_position":2}"#),
            Stub(200, body: #"{"request_id":"req-1","status":"IN_QUEUE","queue_position":1}"#),
            Stub(200, body: #"{"request_id":"req-1","status":"IN_PROGRESS"}"#),
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED"}"#)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        var seen: [String] = []
        let handle = try makeModels().handle(Self.modelId, requestId: "req-1")
        for try await status in handle.events(timeout: 30) {
            seen.append("\(status.state.rawValue)@\(status.queuePosition.map(String.init) ?? "-")")
        }

        #expect(seen == ["IN_QUEUE@2", "IN_QUEUE@1", "IN_PROGRESS@-", "COMPLETED@-"])
        #expect(log.matching("/status").count == 5)
    }

    @Test("events: a COMPLETED carrying an error_type is YIELDED, not thrown — the stream is a view, result() is the collector")
    func events_yields_a_reported_completion_failure() async throws {
        var routes = Routes()
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED","error_type":"insufficient_credits"}"#)
        ]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        let handle = try makeModels().handle(Self.modelId, requestId: "req-1")
        var seen: [RouterRequestStatus] = []
        for try await status in handle.events(timeout: 30) { seen.append(status) }

        #expect(seen.count == 1)
        #expect(seen.first?.state == .completed)
        #expect(seen.first?.errorType == .insufficientCredits)
    }

    @Test("events: timeout 0 reads 'look once', then throws .timeout into the stream without cancelling")
    func events_timeout_zero_looks_once() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [Stub(200, body: #"{"request_id":"req-1","status":"IN_QUEUE"}"#)]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let handle = try makeModels().handle(Self.modelId, requestId: "req-1")
        var seen = 0
        do {
            for try await _ in handle.events(timeout: 0) { seen += 1 }
            Issue.record("expected a throw")
        } catch {
            Self.expectTimeout(error)
        }
        #expect(seen == 1)
        #expect(log.matching("/status").count == 1)
        #expect(log.matching("/cancel").isEmpty)
    }

    @Test("events: cancelling the consuming task ends the stream WITHOUT throwing, and stops the polling")
    func events_consumer_cancellation_ends_the_stream_without_throwing() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [Stub(200, body: #"{"request_id":"req-1","status":"IN_QUEUE","queue_position":1}"#)]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let handle = try makeModels().handle(Self.modelId, requestId: "req-1")
        let consumer = Task { () -> String in
            do {
                for try await _ in handle.events(timeout: 30) {}
                return Task.isCancelled ? "finished-while-cancelled" : "finished"
            } catch {
                return "threw \(error)"
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        consumer.cancel()

        // What the handle's documentation now says, and the reason it no longer promises
        // `.cancelled`: the consumer's own cancellation terminates the stream, so the
        // `ComfyError.cancelled` the poll loop then raises has nobody left to deliver it to.
        let outcome = await consumer.value
        #expect(outcome == "finished-while-cancelled")

        // And the poller really is torn down by `onTermination` rather than left running
        // against the server for the rest of its 30 s budget.
        let pollsWhenCancelled = log.matching("/status").count
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(log.matching("/status").count == pollsWhenCancelled)
    }

    // MARK: - subscribe

    @Test("subscribe: submit, poll, collect — one of each route, the result of the last")
    func subscribe_is_submit_plus_poll_plus_collect() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.submit = [Stub(201, body: #"{"request_id":"req-1","status":"IN_QUEUE","queue_position":3}"#)]
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"IN_PROGRESS"}"#),
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED"}"#)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let updates = UpdateLog()
        let result = try await makeModels().subscribe(
            Self.modelId,
            input: ["prompt": "a cat"],
            onQueueUpdate: { updates.append($0) },
            timeout: 30
        )

        #expect(result.output["images"][0]["url"].stringValue == "https://cdn.example.test/a.png")
        #expect(log.matching("/requests").count == 1)
        #expect(log.matching("/status").count == 2)
        #expect(log.matching("/cancel").isEmpty)
        // The result fetch carries the key the submit ran under.
        #expect(result.idempotencyKey == log.entries.first?.headers["Idempotency-Key"])
        // The submit's own acknowledgement is the first update, so a caller sees a queue
        // position before the first poll rather than after it.
        #expect(updates.observations == ["IN_QUEUE@3", "IN_PROGRESS@-", "COMPLETED@-"])
    }

    @Test("subscribe: the submit acknowledgement and a first poll reading the same position are ONE event")
    func subscribe_does_not_double_report_the_submitted_position() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.submit = [Stub(201, body: #"{"request_id":"req-1","status":"IN_QUEUE","queue_position":3}"#)]
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"IN_QUEUE","queue_position":3}"#),
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED"}"#)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let updates = UpdateLog()
        _ = try await makeModels().subscribe(
            Self.modelId,
            input: ["prompt": "a cat"],
            onQueueUpdate: { updates.append($0) },
            timeout: 30
        )

        #expect(updates.observations == ["IN_QUEUE@3", "COMPLETED@-"])
    }

    @Test("subscribe: an oversized acknowledgement status is capped before it reaches onQueueUpdate")
    func subscribe_caps_the_acknowledgement_status() async throws {
        let huge = String(repeating: "Z", count: 4096)
        var routes = Routes()
        routes.submit = [Stub(201, body: #"{"request_id":"req-1","status":"\#(huge)"}"#)]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        let updates = UpdateLog()
        _ = try await makeModels().subscribe(
            Self.modelId,
            input: ["prompt": "a cat"],
            onQueueUpdate: { updates.append($0) },
            timeout: 30
        )

        // The acknowledgement is the FIRST update a caller sees, and it is the one path that
        // used to skip the 128-scalar cap the status route applies to the same field.
        let acknowledged = try #require(updates.events.first)
        #expect(acknowledged.state.rawValue.unicodeScalars.count == 128)
        #expect(acknowledged.state.isTerminal == false)
    }

    @Test("subscribe: a blank acknowledgement status reads as IN_QUEUE, not as an unknown empty state")
    func subscribe_reads_a_blank_acknowledgement_status_as_queued() async throws {
        var routes = Routes()
        routes.submit = [Stub(201, body: #"{"request_id":"req-1","status":"","queue_position":2}"#)]
        installStub(routes, log: RequestLog())
        defer { TestURLProtocol.uninstall() }

        let updates = UpdateLog()
        _ = try await makeModels().subscribe(
            Self.modelId,
            input: ["prompt": "a cat"],
            onQueueUpdate: { updates.append($0) },
            timeout: 30
        )

        // `status` is optional on this route — a conforming `201` says `IN_QUEUE` and silence
        // means the same — so a blank one is "not reported", never `.unknown("")`.
        #expect(updates.observations.first == "IN_QUEUE@2")
    }

    @Test("every queue URL is composed from the contract templates — the response's own *_url fields are never followed")
    func queue_urls_are_composed_never_taken_from_the_response() async throws {
        let log = RequestLog()
        var routes = Routes()
        // A hostile acknowledgement: every URL it names points somewhere else entirely, and
        // following any of them would send the caller's credential there.
        routes.submit = [
            Stub(201, body: """
            {"request_id":"req-1","status":"IN_QUEUE",
             "status_url":"https://evil.test/status",
             "response_url":"https://evil.test/result",
             "cancel_url":"https://evil.test/cancel"}
            """)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        _ = try await makeModels().subscribe(Self.modelId, input: ["prompt": "a cat"], timeout: 30)

        let hosts = Set(log.entries.compactMap { $0.url?.host })
        #expect(hosts == ["api.comfy.org"])
        #expect(log.matching("/status").first?.url?.absoluteString == Self.statusURL)
    }

    @Test("subscribe: a COMPLETED with an error_type throws the bucket and never fetches a result")
    func subscribe_never_returns_a_failed_completion_as_success() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED","error_type":"provider_error"}"#)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeModels().subscribe(Self.modelId, input: ["prompt": "a cat"], timeout: 30)
            Issue.record("expected a throw")
        } catch {
            let routerError = try #require(Self.routerError(from: error))
            #expect(routerError.errorType == .providerError)
        }

        // The `200` the result route would have answered must never be reached: a completion
        // that reported a failure is not a result to collect.
        #expect(log.matching("/status").count == 1)
        let resultFetches = log.entries.filter { $0.url?.absoluteString == Self.resultURL }
        #expect(resultFetches.isEmpty)
        // A terminal failure is server-side already — nothing to cancel on the way out.
        #expect(log.matching("/cancel").isEmpty)
    }

    @Test("subscribe: the timeout is a real wall-clock stop, and issues exactly ONE best-effort PUT cancel")
    func subscribe_timeout_cancels_once_then_throws() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [Stub(200, body: #"{"request_id":"req-1","status":"IN_PROGRESS"}"#)]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let started = ContinuousClock.now
        do {
            _ = try await makeModels().subscribe(
                Self.modelId,
                input: ["prompt": "a cat"],
                timeout: 1
            )
            Issue.record("expected a throw")
        } catch {
            Self.expectTimeout(error)
        }
        let elapsed = started.duration(to: ContinuousClock.now)
        #expect(elapsed < .seconds(5))

        let cancels = log.matching("/cancel")
        #expect(cancels.count == 1)
        #expect(cancels.first?.method == "PUT")
        #expect(log.entries.last?.url?.absoluteString == Self.cancelURL)
    }

    @Test("subscribe: a failing best-effort cancel never masks the timeout it is cleaning up after")
    func subscribe_cancel_failure_does_not_mask_the_timeout() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [Stub(200, body: #"{"request_id":"req-1","status":"IN_PROGRESS"}"#)]
        routes.cancel = [Stub(500, body: #"{"error_type":"internal_error","detail":"boom"}"#)]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeModels().subscribe(Self.modelId, input: ["prompt": "a cat"], timeout: 1)
            Issue.record("expected a throw")
        } catch {
            Self.expectTimeout(error)
        }
        #expect(log.matching("/cancel").count == 1)
    }

    @Test("subscribe: cancelling the calling task throws .cancelled and issues one best-effort cancel")
    func subscribe_honours_structured_concurrency_cancellation() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [Stub(200, body: #"{"request_id":"req-1","status":"IN_PROGRESS"}"#)]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let models = makeModels()
        let task = Task { () -> RouterRunResult in
            try await models.subscribe(Self.modelId, input: ["prompt": "a cat"], timeout: 30)
        }
        // Long enough for the submit and the first poll to land, short enough to be inside the
        // first 0.5 s schedule pause.
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected a throw")
        } catch {
            Self.expectCancelled(error)
        }

        let cancels = log.matching("/cancel")
        #expect(cancels.count == 1)
        #expect(cancels.first?.method == "PUT")
    }

    @Test("subscribe: an unknown status is not terminal — polling continues through it")
    func subscribe_keeps_polling_through_an_unknown_status() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [
            Stub(200, body: #"{"request_id":"req-1","status":"RECONCILING"}"#),
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED"}"#)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let updates = UpdateLog()
        _ = try await makeModels().subscribe(
            Self.modelId,
            input: ["prompt": "a cat"],
            onQueueUpdate: { updates.append($0) },
            timeout: 30
        )

        #expect(log.matching("/status").count == 2)
        #expect(updates.observations.contains("RECONCILING@-"))
    }

    // MARK: - Poll schedule

    @Test("a server Retry-After beats the schedule: one hint of 1 s replaces the 0.5 s first pause")
    func poll_honours_a_server_retry_after_over_its_own_schedule() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [
            Stub(200, headers: ["Retry-After": "1"], body: #"{"request_id":"req-1","status":"IN_QUEUE"}"#),
            Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED"}"#)
        ]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

        let handle = try makeModels().handle(Self.modelId, requestId: "req-1")
        let started = ContinuousClock.now
        for try await _ in handle.events(timeout: 30) {}
        let elapsed = started.duration(to: ContinuousClock.now)

        // The schedule alone would have paused 0.5 s; the server asked for 1 s and got it.
        #expect(elapsed >= .milliseconds(900))
        #expect(elapsed < .seconds(3))
        #expect(log.matching("/status").count == 2)
    }

    @Test("the first poll is always made — a budget already spent still reads the status once")
    func poll_always_looks_once() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [Stub(200, body: #"{"request_id":"req-1","status":"COMPLETED"}"#)]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

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
        let path = try RouterTransport.parseModelId(Self.modelId)

        // A deadline that has ALREADY passed. Every guard in the loop would refuse it; the
        // first-poll floor is what makes "look once" mean what it says.
        let status = try await transport.pollUntilTerminal(
            path: path,
            requestId: "req-1",
            encodedRequestId: "req-1",
            deadline: ContinuousClock.now.advanced(by: .seconds(-5)),
            throwsOnCompletionFailure: true,
            onEvent: nil
        )

        #expect(status.state == .completed)
        #expect(log.matching("/status").count == 1)
    }

    @Test("a spent budget still throws .timeout once the first poll has been made and is not terminal")
    func poll_stops_at_the_deadline_after_looking_once() async throws {
        let log = RequestLog()
        var routes = Routes()
        routes.status = [Stub(200, body: #"{"request_id":"req-1","status":"IN_PROGRESS"}"#)]
        installStub(routes, log: log)
        defer { TestURLProtocol.uninstall() }

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
        let path = try RouterTransport.parseModelId(Self.modelId)

        do {
            _ = try await transport.pollUntilTerminal(
                path: path,
                requestId: "req-1",
                encodedRequestId: "req-1",
                deadline: ContinuousClock.now.advanced(by: .seconds(-5)),
                throwsOnCompletionFailure: true,
                onEvent: nil
            )
            Issue.record("expected a throw")
        } catch {
            Self.expectTimeout(error)
        }
        #expect(log.matching("/status").count == 1)
    }

    // MARK: - Helpers

    /// Collects `onQueueUpdate` callbacks, which fire from the SDK's own task.
    private final class UpdateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [RouterRequestStatus] = []
        func append(_ status: RouterRequestStatus) {
            lock.lock(); defer { lock.unlock() }
            _events.append(status)
        }
        var events: [RouterRequestStatus] { lock.lock(); defer { lock.unlock() }; return _events }
        /// The two fields a change is judged on, which is what the assertions care about.
        var observations: [String] {
            events.map { "\($0.state.rawValue)@\($0.queuePosition.map(String.init) ?? "-")" }
        }
    }
}
