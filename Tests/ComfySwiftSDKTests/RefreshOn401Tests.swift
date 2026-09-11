import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("RefreshOn401 — Story 8.5 AC3-AC6", .serialized)
struct RefreshOn401Tests {

    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func increment() { lock.lock(); defer { lock.unlock() }; _count += 1 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _accessToken: String
        init(_ initial: String) { _accessToken = initial }
        var accessToken: String { lock.lock(); defer { lock.unlock() }; return _accessToken }
        func set(_ token: String) { lock.lock(); defer { lock.unlock() }; _accessToken = token }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        func record(_ event: String) { lock.lock(); defer { lock.unlock() }; _events.append(event) }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
    }

    final class AsyncLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var signaled = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        func signal() {
            lock.lock()
            let pending = continuations
            signaled = true
            continuations = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if signaled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    private static let baseURL = URL(string: "https://cloud.comfy.org")!
    private static let staleToken = "current-access-token"
    private static let freshToken = "refreshed-access-token"
    private static let refreshResponseJSON = """
        {"access_token":"refreshed-access-token","refresh_token":"new-refresh-token","expires_in":900}
        """

    private func makeRefreshableCredential(
        tokenBox: TokenBox,
        expiryOffset: TimeInterval?,
        tokenStoreCounter: CallCounter? = nil,
        eventLog: EventLog? = nil,
        refreshToken: String = "current-refresh-token",
        refreshProviderGate: (@Sendable () async throws -> Void)? = nil
    ) -> ComfyCredential {
        .oauthRefreshable(
            tokenProvider: { tokenBox.accessToken },
            refreshProvider: {
                if let refreshProviderGate {
                    try await refreshProviderGate()
                }
                return refreshToken
            },
            tokenStore: { response in
                tokenBox.set(response.accessToken)
                tokenStoreCounter?.increment()
                eventLog?.record("tokenStore")
            },
            expiryProvider: {
                expiryOffset.map { Date().addingTimeInterval($0) }
            }
        )
    }

    private func makeTransport(credential: ComfyCredential) -> Transport {
        Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: Self.baseURL,
            credential: credential
        )
    }

    private static func ok(_ request: URLRequest, body: String = "{}") -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body.data(using: .utf8)!)
    }

    private static func unauthorized(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 401,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, #"{"error":"unauthorized"}"#.data(using: .utf8)!)
    }

    /// An arbitrary-status token-endpoint response, for the RFC 6749 §5.2 error
    /// bodies the refresh POST answers with.
    private static func status(
        _ request: URLRequest,
        _ code: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body.data(using: .utf8)!)
    }

    private func installMock(
        refreshCounter: CallCounter,
        queueCounter: CallCounter,
        refreshStatus: Int = 200,
        refreshErrorBody: String? = nil,
        eventLog: EventLog? = nil,
        queueResponder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))? = nil
    ) {
        TestURLProtocol.install { request in
            switch request.url?.path {
            case "/oauth/token":
                refreshCounter.increment()
                eventLog?.record("refresh-endpoint")
                if refreshStatus == 200 {
                    return Self.ok(request, body: Self.refreshResponseJSON)
                }
                if let refreshErrorBody {
                    return Self.status(request, refreshStatus, body: refreshErrorBody)
                }
                return Self.unauthorized(request)
            case "/api/queue":
                queueCounter.increment()
                let auth = request.value(forHTTPHeaderField: "Authorization") ?? "<none>"
                eventLog?.record("queue(\(auth == "Bearer \(Self.freshToken)" ? "fresh" : "stale"))")
                if let queueResponder {
                    return queueResponder(request)
                }
                if auth == "Bearer \(Self.freshToken)" {
                    return Self.ok(request)
                }
                return Self.unauthorized(request)
            default:
                Issue.record("Unexpected request path: \(request.url?.path ?? "<nil>")")
                throw URLError(.badURL)
            }
        }
    }

    @Test("proactive refresh fires when the token is within the 60s margin")
    func proactive_refresh_fires_when_token_near_expiry() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        let eventLog = EventLog()
        installMock(refreshCounter: refreshCounter, queueCounter: queueCounter, eventLog: eventLog)
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 30, eventLog: eventLog)
        )
        try await transport.validateAuth()

        #expect(refreshCounter.count == 1)
        #expect(queueCounter.count == 1)
        #expect(eventLog.events.contains("queue(fresh)"))
        #expect(!eventLog.events.contains("queue(stale)"))
    }

    @Test("no proactive refresh when the token is far from expiry")
    func no_proactive_refresh_when_token_far_from_expiry() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        let eventLog = EventLog()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            eventLog: eventLog,
            queueResponder: { Self.ok($0) }
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300, eventLog: eventLog)
        )
        try await transport.validateAuth()

        #expect(refreshCounter.count == 0)
        #expect(eventLog.events == ["queue(stale)"])
    }

    @Test("proactive refresh fires when no expiry is stored (nil → treated as expired)")
    func proactive_refresh_fires_when_expiry_is_nil() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(refreshCounter: refreshCounter, queueCounter: queueCounter)
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: nil)
        )
        try await transport.validateAuth()

        #expect(refreshCounter.count == 1)
    }

    @Test("401 triggers exactly one refresh and a successful retry")
    func test401_triggers_refresh_then_successful_retry() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(refreshCounter: refreshCounter, queueCounter: queueCounter)
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        try await transport.validateAuth()

        #expect(refreshCounter.count == 1)
        #expect(queueCounter.count == 2)
        #expect(tokenBox.accessToken == Self.freshToken)
    }

    @Test("second 401 after a successful refresh surfaces .authExpired, never a loop")
    func second_401_after_refresh_surfaces_authExpired() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            queueResponder: { Self.unauthorized($0) }
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authExpired, got success")
        } catch ComfyError.authExpired {
        } catch {
            Issue.record("Expected .authExpired, got \(error)")
        }

        #expect(refreshCounter.count == 1)
        #expect(queueCounter.count == 2)
    }

    // 401 on the refresh POST is the DEFENCE-IN-DEPTH path, not the production one:
    // cloud.comfy.org's token endpoint answers a dead refresh token with an RFC 6749
    // §5.2 `400 {"error":"invalid_grant"}` (covered by the next test). A 401 here
    // models a proxy or CDN in front of that endpoint answering instead.
    @Test("refresh failure (401 on the refresh POST — defence in depth) surfaces .authExpired")
    func refresh_failure_surfaces_authExpired() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 401
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authExpired, got success")
        } catch ComfyError.authExpired {
        } catch {
            Issue.record("Expected .authExpired, got \(error)")
        }

        #expect(refreshCounter.count == 1)
        #expect(queueCounter.count == 1)
    }

    @Test("400 invalid_grant on the refresh POST surfaces .authExpired, not .network")
    func refresh_400_invalid_grant_surfaces_authExpired() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: #"{"error":"invalid_grant","error_description":"refresh token expired"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authExpired, got success")
        } catch ComfyError.authExpired {
        } catch {
            Issue.record("Expected .authExpired, got \(error)")
        }

        #expect(refreshCounter.count == 1)
        #expect(queueCounter.count == 1)
    }

    @Test("400 invalid_grant with no error_description still surfaces .authExpired")
    func refresh_400_invalid_grant_without_description_surfaces_authExpired() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: #"{"error":"invalid_grant"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authExpired, got success")
        } catch ComfyError.authExpired {
        } catch {
            Issue.record("Expected .authExpired, got \(error)")
        }

        #expect(refreshCounter.count == 1)
    }

    // A non-`invalid_grant` 400 is a client implementation bug, so it must NOT reach
    // the caller as `.authExpired` (which would trigger a pointless re-sign-in) nor as
    // `.network` (which would invite a retry that can never succeed).
    @Test("400 invalid_request on the refresh POST surfaces .unknown")
    func refresh_400_invalid_request_surfaces_unknown() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: #"{"error":"invalid_request"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .unknown, got success")
        } catch ComfyError.unknown(let underlying) {
            let endpointError = try #require(underlying as? OAuthTokenEndpointError)
            #expect(endpointError.code == "invalid_request")
        } catch {
            Issue.record("Expected .unknown, got \(error)")
        }

        #expect(refreshCounter.count == 1)
    }

    @Test("400 with an unparseable body on the refresh POST surfaces .unknown")
    func refresh_400_unparseable_body_surfaces_unknown() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: "<html>400 Bad Request</html>"
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .unknown, got success")
        } catch ComfyError.unknown(let underlying) {
            let endpointError = try #require(underlying as? OAuthTokenEndpointError)
            #expect(endpointError.code == nil)
        } catch {
            Issue.record("Expected .unknown, got \(error)")
        }

        #expect(refreshCounter.count == 1)
    }

    // The ticket's own scenario reaches the refresh POST via the PROACTIVE path
    // (`Transport.refreshIfNearExpiry`), which runs inside `normalizeToken` rather
    // than through the 401 retry — a different chain of catch-arms, so it needs its
    // own coverage: a `ComfyError` that `normalizeToken` failed to re-throw verbatim
    // would arrive as `.authInvalid` here while the reactive tests above stayed green.
    @Test("proactive refresh hitting 400 invalid_grant surfaces .authExpired before any API call")
    func proactive_refresh_400_invalid_grant_surfaces_authExpired() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: #"{"error":"invalid_grant","error_description":"refresh token reuse detected"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 30)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authExpired, got success")
        } catch ComfyError.authExpired {
        } catch {
            Issue.record("Expected .authExpired, got \(error)")
        }

        #expect(refreshCounter.count == 1)
        #expect(queueCounter.count == 0)
    }

    // NFR-S2: the refresh token must not survive into an error a consumer may log.
    // The 400 body carries no token fields of its own, so the exposure this guards
    // is a server echoing our own `refresh_token` back inside `error_description`.
    @Test("400 error_description echoing the refresh token is redacted before it reaches the caller")
    func refresh_400_redacts_echoed_refresh_token() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: #"{"error":"invalid_request","error_description":"grant current-refresh-token is malformed"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .unknown, got success")
        } catch ComfyError.unknown(let underlying) {
            let rendered = String(describing: underlying)
            #expect(!rendered.contains("current-refresh-token"), "NFR-S2 VIOLATION: refresh token leaked into \(rendered)")
            #expect(rendered.contains("<redacted>"))
        } catch {
            Issue.record("Expected .unknown, got \(error)")
        }
    }

    // The refresh grant's half of the length-floor split: the floor is scoped to the
    // RFC `error` code, so a refresh token too short to clear it must still be struck
    // from the free-text `error_description`. Seven characters — one under the floor.
    @Test("400 error_description echoing a SHORT refresh token is redacted too")
    func refresh_400_redacts_short_refresh_token() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: #"{"error":"invalid_request","error_description":"grant abc1234 is malformed"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(
                tokenBox: tokenBox,
                expiryOffset: 300,
                refreshToken: "abc1234"
            )
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .unknown, got success")
        } catch ComfyError.unknown(let underlying) {
            let rendered = String(describing: underlying)
            #expect(!rendered.contains("abc1234"), "NFR-S2 VIOLATION: short refresh token leaked into \(rendered)")
            #expect(rendered.contains("<redacted>"))
        } catch {
            Issue.record("Expected .unknown, got \(error)")
        }
    }

    // The companion to the test above, for the variant a plain string match misses:
    // the body is sent percent-encoded, so a standard-base64 refresh token goes out
    // as `ab%2Bcd%2Fef%3D` and a server echoing back the raw form value it received
    // would slip past a redaction that only knows the decoded value.
    @Test("400 error_description echoing the PERCENT-ENCODED refresh token is redacted too")
    func refresh_400_redacts_percent_encoded_refresh_token() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: #"{"error":"invalid_request","error_description":"grant ab%2Bcd%2Fef%3D is malformed"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(
                tokenBox: tokenBox,
                expiryOffset: 300,
                refreshToken: "ab+cd/ef="
            )
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .unknown, got success")
        } catch ComfyError.unknown(let underlying) {
            let rendered = String(describing: underlying)
            #expect(!rendered.contains("ab%2Bcd%2Fef%3D"), "NFR-S2 VIOLATION: encoded refresh token leaked into \(rendered)")
            #expect(!rendered.contains("ab+cd/ef="), "NFR-S2 VIOLATION: refresh token leaked into \(rendered)")
            #expect(rendered.contains("<redacted>"))
        } catch {
            Issue.record("Expected .unknown, got \(error)")
        }
    }

    // The re-authentication route must not hinge on the endpoint's casing: a proxy
    // answering `Invalid_Grant` (or padding the value) would otherwise leave a dead
    // refresh token classified `.unknown`, with no way back into sign-in.
    @Test("400 invalid_grant is matched case- and whitespace-insensitively")
    func refresh_400_invalid_grant_is_normalized_before_matching() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: #"{"error":"  Invalid_Grant\n"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authExpired, got success")
        } catch ComfyError.authExpired {
        } catch {
            Issue.record("Expected .authExpired, got \(error)")
        }

        #expect(refreshCounter.count == 1)
    }

    // `code` is documented as `nil` when there is nothing usable to branch on, so an
    // `error` of `""` must not reach a consumer as an empty-but-non-nil code.
    @Test("400 with an empty error code surfaces code == nil, keeping the description")
    func refresh_400_empty_error_code_is_nil() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: #"{"error":"","error_description":"nothing useful"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .unknown, got success")
        } catch ComfyError.unknown(let underlying) {
            let endpointError = try #require(underlying as? OAuthTokenEndpointError)
            #expect(endpointError.code == nil)
            #expect(endpointError.detail == "nothing useful")
            #expect(!endpointError.description.hasSuffix(" "))
        } catch {
            Issue.record("Expected .unknown, got \(error)")
        }
    }

    // `errorDescription` puts these server-controlled strings into
    // `localizedDescription`, which consumers log and render — so a body carrying
    // newlines or ANSI escapes must not be able to forge log lines or alert text.
    @Test("400 error strings are stripped of control characters before they reach the caller")
    func refresh_400_flattens_control_characters() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            refreshStatus: 400,
            refreshErrorBody: #"{"error":"invalid_request","error_description":"first\n\u001b[31mERROR: forged\u202e line"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(tokenBox: tokenBox, expiryOffset: 300)
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .unknown, got success")
        } catch ComfyError.unknown(let underlying) {
            let endpointError = try #require(underlying as? OAuthTokenEndpointError)
            let detail = try #require(endpointError.detail)
            #expect(!detail.contains("\n"))
            #expect(!detail.contains("\u{1B}"))
            #expect(!detail.contains("\u{202E}"))
            #expect(detail.contains("forged"))
        } catch {
            Issue.record("Expected .unknown, got \(error)")
        }
    }

    // `clamp` bounds by UTF-8 bytes, not `count`: a single grapheme cluster made of
    // one base character plus thousands of combining marks has `count == 1` and would
    // sail through a character-based cap intact.
    @Test("clamp bounds a combining-mark run by byte length, ellipsis included")
    func clamp_bounds_by_utf8_bytes() {
        let bomb = "a" + String(repeating: "\u{0301}", count: 5_000)
        let clamped = OAuthTokenEndpointError.clamp(bomb, to: 200)
        #expect(clamped.utf8.count <= 200)

        let plain = String(repeating: "x", count: 300)
        #expect(OAuthTokenEndpointError.clamp(plain, to: 200).utf8.count <= 200)
        #expect(OAuthTokenEndpointError.clamp("short", to: 200) == "short")
    }

    @Test("apiKey mode 401 still surfaces .authInvalid (no refresh machinery) — regression")
    func apiKey_mode_401_still_surfaces_authInvalid() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            queueResponder: { Self.unauthorized($0) }
        )
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(credential: .apiKey("test-key"))
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }

        #expect(refreshCounter.count == 0)
        #expect(queueCounter.count == 1)
    }

    @Test("tokenStore is called BEFORE the retried request reaches the server")
    func tokenStore_called_before_retry_request() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        let tokenStoreCounter = CallCounter()
        let eventLog = EventLog()
        installMock(refreshCounter: refreshCounter, queueCounter: queueCounter, eventLog: eventLog)
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(
                tokenBox: tokenBox,
                expiryOffset: 300,
                tokenStoreCounter: tokenStoreCounter,
                eventLog: eventLog
            )
        )
        try await transport.validateAuth()

        #expect(tokenStoreCounter.count == 1)
        #expect(eventLog.events == ["queue(stale)", "refresh-endpoint", "tokenStore", "queue(fresh)"])
    }

    @Test("N concurrent 401s coalesce into exactly one refresh network call")
    func concurrent_401s_trigger_exactly_one_refresh() async throws {
        let refreshCounter = CallCounter()
        let queueCounter = CallCounter()
        let staleCounter = CallCounter()
        let allStale401sServed = AsyncLatch()
        installMock(
            refreshCounter: refreshCounter,
            queueCounter: queueCounter,
            queueResponder: { request in
                let auth = request.value(forHTTPHeaderField: "Authorization")
                if auth == "Bearer \(Self.freshToken)" {
                    return Self.ok(request)
                }
                staleCounter.increment()
                if staleCounter.count >= 3 {
                    allStale401sServed.signal()
                }
                return Self.unauthorized(request)
            }
        )
        defer { TestURLProtocol.uninstall() }

        let tokenBox = TokenBox(Self.staleToken)
        let transport = makeTransport(
            credential: makeRefreshableCredential(
                tokenBox: tokenBox,
                expiryOffset: 300,
                refreshProviderGate: {
                    await allStale401sServed.wait()
                    try await Task.sleep(for: .milliseconds(100))
                }
            )
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { try await transport.validateAuth() }
            }
            try await group.waitForAll()
        }

        #expect(refreshCounter.count == 1)
        #expect(queueCounter.count >= 3)
    }
}
