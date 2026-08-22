import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("BearerInjection — Story 8.5 AC1/AC2", .serialized)
struct BearerInjectionTests {

    private final class RequestCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []

        func record(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            _requests.append(request)
        }

        var requests: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }
    }

    private static let baseURL = URL(string: "https://cloud.comfy.org")!

    private func makeTransport(credential: ComfyCredential) -> Transport {
        Transport(
            session: TestURLProtocol.makeStubSession(),
            baseURL: Self.baseURL,
            credential: credential
        )
    }

    private func makeRefreshableCredential(token: String) -> ComfyCredential {
        .oauthRefreshable(
            tokenProvider: { token },
            refreshProvider: { "unused-refresh-token" },
            tokenStore: { _ in },
            expiryProvider: { Date.distantFuture }
        )
    }

    private func installCapture(status: Int = 200) -> RequestCapture {
        let capture = RequestCapture()
        TestURLProtocol.install { request in
            capture.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, "{}".data(using: .utf8)!)
        }
        return capture
    }

    private static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    @Test("oauthRefreshable HTTP request carries Authorization: Bearer and no X-API-Key")
    func oauthRefreshable_http_request_carries_Bearer_header() async throws {
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: makeRefreshableCredential(token: "test-access-token")
        )
        try await transport.validateAuth()

        let request = try #require(capture.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == nil)
    }

    @Test("apiKey HTTP request carries X-API-Key and no Authorization (AC1 coexistence regression)")
    func apiKey_http_request_carries_X_API_Key_header() async throws {
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(credential: .apiKey("test-key"))
        try await transport.validateAuth()

        let request = try #require(capture.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("oauthRefreshable WebSocket URL carries ?token=<jwt>")
    func oauthRefreshable_websocket_url_carries_token_query_param() async throws {
        let url = try await WebSocketSession.buildWebSocketURL(
            baseURL: Self.baseURL,
            credential: makeRefreshableCredential(token: "ws-jwt-token"),
            clientID: "test-client-id"
        )
        #expect(url.scheme == "wss")
        #expect(Self.queryValue("token", in: url) == "ws-jwt-token")
        #expect(Self.queryValue("clientId", in: url) == "test-client-id")
    }

    @Test("oauth WebSocket URL carries ?token=<jwt> (TODO(8.5) resolved for the 8.2 case too)")
    func oauth_websocket_url_carries_token_query_param() async throws {
        let url = try await WebSocketSession.buildWebSocketURL(
            baseURL: Self.baseURL,
            credential: .oauth(tokenProvider: { "ws-jwt-token" }),
            clientID: "test-client-id"
        )
        #expect(Self.queryValue("token", in: url) == "ws-jwt-token")
    }

    @Test("apiKey WebSocket URL byte-identical: ?token=<key> (AC2 coexistence regression)")
    func apiKey_websocket_url_carries_token_query_param() async throws {
        let url = try await WebSocketSession.buildWebSocketURL(
            baseURL: Self.baseURL,
            credential: .apiKey("test-key"),
            clientID: "test-client-id"
        )
        #expect(url.scheme == "wss")
        #expect(url.path == "/ws")
        #expect(Self.queryValue("token", in: url) == "test-key")
        #expect(Self.queryValue("clientId", in: url) == "test-client-id")
    }

    @Test("oauthRefreshable WebSocket URL build fails typed when the provider throws")
    func oauthRefreshable_websocket_provider_failure_throws_authInvalid() async throws {
        struct ProviderFailure: Error {}
        let credential = ComfyCredential.oauthRefreshable(
            tokenProvider: { throw ProviderFailure() },
            refreshProvider: { "unused" },
            tokenStore: { _ in },
            expiryProvider: { Date.distantFuture }
        )
        do {
            _ = try await WebSocketSession.buildWebSocketURL(
                baseURL: Self.baseURL,
                credential: credential
            )
            Issue.record("Expected .authInvalid, got a URL")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("oauthRefreshable WebSocket URL build rejects an empty token")
    func oauthRefreshable_websocket_empty_token_throws_authInvalid() async throws {
        let credential = makeRefreshableCredential(token: "")
        do {
            _ = try await WebSocketSession.buildWebSocketURL(
                baseURL: Self.baseURL,
                credential: credential
            )
            Issue.record("Expected .authInvalid, got a URL")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    // Characterization: pin the shared normalizeToken(_:) contract on the two
    // HTTP header branches not directly asserted elsewhere. Behavior-preserving refactor.

    @Test(".oauth HTTP header path maps a throwing tokenProvider to .authInvalid")
    func oauth_http_header_throwing_provider_throws_authInvalid() async throws {
        struct ProviderFailure: Error {}
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: .oauth(tokenProvider: { throw ProviderFailure() })
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
        // Non-ComfyError from the provider is mapped before any request leaves.
        #expect(capture.requests.isEmpty)
    }

    @Test(".oauth HTTP header path maps an empty token to .authInvalid")
    func oauth_http_header_empty_token_throws_authInvalid() async throws {
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: .oauth(tokenProvider: { "" })
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
        #expect(capture.requests.isEmpty)
    }

    // Pins Step 3's invariant: refreshIfNearExpiry(...) stays INSIDE the normalizeToken
    // closure, so its non-ComfyError throws map to .authInvalid. Here expiryProvider throws
    // a non-ComfyError, which applyAuth's normalizeToken maps to .authInvalid. Because the
    // credential is .oauthRefreshable, withAuthRetry then retries via performRefresh; the
    // refreshProvider deliberately throws ComfyError.authInvalid so that retry re-surfaces
    // .authInvalid unchanged (rather than a decode/network error muddying the assertion).
    // If refreshIfNearExpiry were hoisted OUT of the closure, expiryProvider's ProviderFailure
    // would escape unmapped and this catch would see ProviderFailure instead — the regression
    // this test exists to catch.
    @Test("oauthRefreshable HTTP path maps a non-ComfyError from refreshIfNearExpiry to .authInvalid")
    func oauthRefreshable_http_refresh_nonComfyError_throws_authInvalid() async throws {
        struct ProviderFailure: Error {}
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let credential = ComfyCredential.oauthRefreshable(
            tokenProvider: { "unused-access-token" },
            refreshProvider: { throw ComfyError.authInvalid },
            tokenStore: { _ in },
            expiryProvider: { throw ProviderFailure() }
        )
        let transport = makeTransport(credential: credential)
        do {
            try await transport.validateAuth()
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
        // The mapping happens before any authenticated request is issued.
        #expect(capture.requests.isEmpty)
    }

    // Cancellation contract: normalizeToken must NOT collapse cooperative
    // cancellation into .authInvalid. Swallowing it would (a) misreport a cancelled auth
    // fetch as a rejected credential and (b) — on .oauthRefreshable — make withAuthRetry
    // trigger a spurious refresh/retry. These two tests pin both halves.

    @Test(".oauth HTTP header path surfaces provider CancellationError as .cancelled")
    func oauth_http_header_cancellation_surfaces_cancelled() async throws {
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let transport = makeTransport(
            credential: .oauth(tokenProvider: { throw CancellationError() })
        )
        do {
            try await transport.validateAuth()
            Issue.record("Expected .cancelled, got success")
        } catch ComfyError.cancelled {
        } catch {
            Issue.record("Expected .cancelled, got \(error)")
        }
        // Cancellation is surfaced before any request leaves the client.
        #expect(capture.requests.isEmpty)
    }

    // A cancelled token fetch on .oauthRefreshable must propagate as .cancelled WITHOUT
    // withAuthRetry invoking the refreshProvider — that would be spurious refresh work on a
    // cancelled task. refreshProvider records whether it ran and would flip the result to
    // .authExpired (its authInvalid throw, escalated by a second retry) if cancellation were
    // wrongly mapped to .authInvalid.
    @Test("oauthRefreshable HTTP path propagates cancellation without spurious refresh")
    func oauthRefreshable_http_cancellation_no_refresh() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var _hit = false
            func set() { lock.lock(); _hit = true; lock.unlock() }
            var hit: Bool { lock.lock(); defer { lock.unlock() }; return _hit }
        }
        let refreshed = Flag()
        let capture = installCapture()
        defer { TestURLProtocol.uninstall() }

        let credential = ComfyCredential.oauthRefreshable(
            tokenProvider: { throw CancellationError() },
            refreshProvider: { refreshed.set(); throw ComfyError.authInvalid },
            tokenStore: { _ in },
            expiryProvider: { Date.distantFuture }
        )
        let transport = makeTransport(credential: credential)
        do {
            try await transport.validateAuth()
            Issue.record("Expected .cancelled, got success")
        } catch ComfyError.cancelled {
        } catch {
            Issue.record("Expected .cancelled, got \(error)")
        }
        #expect(refreshed.hit == false)
        #expect(capture.requests.isEmpty)
    }
}
