import Testing
import Foundation
import CryptoKit
@testable import ComfySwiftSDK

@Suite("OAuthExchange — AC1/AC2/AC5", .serialized)
struct OAuthExchangeTests {

    private static let base64URLAlphabet = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    private func queryItems(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, last in last }
    }

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
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

    private func formFields(_ body: Data) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = String(data: body, encoding: .utf8)
        let items = components.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { _, last in last }
    }

    private func makeExchanger() -> OAuthExchanger {
        OAuthExchanger(session: TestURLProtocol.makeStubSession())
    }

    private func installTokenEndpoint(
        status: Int,
        body: String,
        capture box: CapturedRequestBox? = nil
    ) {
        TestURLProtocol.install { request in
            box?.store(request, body: Self.bodyData(of: request))
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, body.data(using: .utf8)!)
        }
    }

    final class CapturedRequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _request: URLRequest?
        private var _body = Data()
        func store(_ request: URLRequest, body: Data) {
            lock.lock(); defer { lock.unlock() }
            _request = request
            _body = body
        }
        var request: URLRequest? { lock.lock(); defer { lock.unlock() }; return _request }
        var body: Data { lock.lock(); defer { lock.unlock() }; return _body }
    }

    @Test("buildAuthorizationRequest — all required params present and correct")
    func authorizeURLCarriesAllRequiredParams() throws {
        let request = ComfyCloudClient.buildAuthorizationRequest()
        let url = request.authorizationURL

        #expect(url.absoluteString.hasPrefix(
            OAuthConfiguration.authorizationEndpoint.absoluteString + "?"
        ))

        let params = queryItems(of: url)
        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == "comfy-ios")
        #expect(params["state"]?.isEmpty == false)
        #expect(params["code_challenge"]?.isEmpty == false)
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["scope"] == OAuthClientConfig.comfyIOS.scopes.joined(separator: " "))
        #expect(params["scope"]?.isEmpty == false)
        #expect(params["resource"] == "https://cloud.comfy.org/api")
        #expect(params["redirect_uri"] == "org.comfy.ios://oauth-callback")

        #expect(params["state"] == request.state)
    }

    @Test("code_verifier is 43 base64url chars and fresh per attempt")
    func codeVerifierLengthAndFreshness() {
        let first = ComfyCloudClient.buildAuthorizationRequest()
        let second = ComfyCloudClient.buildAuthorizationRequest()

        #expect(first.codeVerifier.count == 43)
        #expect(second.codeVerifier.count == 43)
        #expect(first.codeVerifier.allSatisfy { Self.base64URLAlphabet.contains($0) })
        #expect(second.codeVerifier.allSatisfy { Self.base64URLAlphabet.contains($0) })

        #expect(first.codeVerifier != second.codeVerifier)
    }

    @Test("code_challenge is BASE64URL(SHA256(code_verifier))")
    func codeChallengeIsS256OfVerifier() throws {
        let request = ComfyCloudClient.buildAuthorizationRequest()

        let digest = SHA256.hash(data: Data(request.codeVerifier.utf8))
        let expected = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        #expect(queryItems(of: request.authorizationURL)["code_challenge"] == expected)
    }

    @Test("state is fresh per attempt")
    func stateFreshness() {
        let states = (0..<3).map { _ in ComfyCloudClient.buildAuthorizationRequest().state }
        #expect(Set(states).count == 3)
    }

    @Test("exchange request is a form-encoded POST with all params and no client_secret")
    func exchangeRequestBodyEncoding() async throws {
        let verifier = "test-verifier-43chars-aaaaaaaaaaaaaaaaaaaaa"
        let box = CapturedRequestBox()
        installTokenEndpoint(
            status: 200,
            body: #"{"access_token":"at","refresh_token":"rt","expires_in":900,"token_type":"Bearer"}"#,
            capture: box
        )
        defer { TestURLProtocol.uninstall() }

        _ = try await makeExchanger().exchange(code: "test-code", codeVerifier: verifier)

        let request = try #require(box.request)
        #expect(request.url == OAuthConfiguration.tokenEndpoint)
        #expect(request.httpMethod == "POST")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")?
                .contains("application/x-www-form-urlencoded") == true
        )

        let fields = formFields(box.body)
        #expect(fields["grant_type"] == "authorization_code")
        #expect(fields["code"] == "test-code")
        #expect(fields["code_verifier"] == verifier)
        #expect(fields["client_id"] == "comfy-ios")
        #expect(fields["resource"] == "https://cloud.comfy.org/api")
        #expect(fields["redirect_uri"] == "org.comfy.ios://oauth-callback")

        #expect(fields["client_secret"] == nil)
    }

    @Test("refresh grant carries the threaded client_id, not a hardcoded comfy-ios")
    func refreshUsesThreadedClientId() async throws {
        let box = CapturedRequestBox()
        installTokenEndpoint(
            status: 200,
            body: #"{"access_token":"at2","refresh_token":"rt2","expires_in":900}"#,
            capture: box
        )
        defer { TestURLProtocol.uninstall() }

        let executor = OAuthTokenRefreshExecutor(session: TestURLProtocol.makeStubSession())
        _ = try await executor.refresh(using: "old-refresh", clientId: "acme-app")

        let fields = formFields(box.body)
        #expect(fields["grant_type"] == "refresh_token")
        #expect(fields["refresh_token"] == "old-refresh")
        #expect(fields["client_id"] == "acme-app")
        #expect(fields["resource"] == "https://cloud.comfy.org/api")
    }

    @Test("token body percent-encodes reserved chars per x-www-form-urlencoded (a raw '+' would decode as space)")
    func tokenBodyPercentEncodesReservedChars() async throws {
        let box = CapturedRequestBox()
        installTokenEndpoint(
            status: 200,
            body: #"{"access_token":"at","refresh_token":"rt","expires_in":900}"#,
            capture: box
        )
        defer { TestURLProtocol.uninstall() }

        // Opaque token carrying every x-www-form-urlencoded delimiter: '+' (standard
        // base64, decoded server-side as a space unless escaped), '/', '=', and '&'
        // (would otherwise split into an injected form field).
        let trickyToken = "ab+cd/ef=gh&ij"
        let executor = OAuthTokenRefreshExecutor(session: TestURLProtocol.makeStubSession())
        _ = try await executor.refresh(using: trickyToken, clientId: "acme-app")

        let raw = String(data: box.body, encoding: .utf8) ?? ""
        #expect(raw.contains("refresh_token=ab%2Bcd%2Fef%3Dgh%26ij"))
        #expect(!raw.contains("ab+cd"))

        // …and it round-trips back to the exact original value.
        #expect(formFields(box.body)["refresh_token"] == trickyToken)
        #expect(formFields(box.body)["client_id"] == "acme-app")
    }

    @Test("refresh grant defaults to the comfy-ios client_id when unthreaded")
    func refreshDefaultsToComfyIOSClientId() async throws {
        let box = CapturedRequestBox()
        installTokenEndpoint(
            status: 200,
            body: #"{"access_token":"at2","refresh_token":"rt2","expires_in":900}"#,
            capture: box
        )
        defer { TestURLProtocol.uninstall() }

        let executor = OAuthTokenRefreshExecutor(session: TestURLProtocol.makeStubSession())
        _ = try await executor.refresh(using: "old-refresh")

        #expect(formFields(box.body)["client_id"] == "comfy-ios")
    }

    @Test("exchange success decodes to OAuthTokenResponse")
    func exchangeSuccessDecodesTokenResponse() async throws {
        installTokenEndpoint(
            status: 200,
            body: #"{"access_token":"at-abc","refresh_token":"rt-xyz","expires_in":900,"token_type":"Bearer"}"#
        )
        defer { TestURLProtocol.uninstall() }

        let response = try await makeExchanger().exchange(
            code: "good-code",
            codeVerifier: "verifier"
        )

        #expect(response.accessToken == "at-abc")
        #expect(response.refreshToken == "rt-xyz")
        #expect(response.expiresIn == 900)
    }

    @Test("exchange HTTP 401 throws .authInvalid")
    func exchange401ThrowsAuthInvalid() async throws {
        installTokenEndpoint(status: 401, body: #"{"error":"invalid_client"}"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(code: "c", codeVerifier: "v")
            Issue.record("Expected .authInvalid, got success")
        } catch ComfyError.authInvalid {
        } catch {
            Issue.record("Expected .authInvalid, got \(error)")
        }
    }

    @Test("exchange HTTP 400 (bad code) throws a ComfyError, never a raw error")
    func exchange400ThrowsComfyError() async throws {
        installTokenEndpoint(status: 400, body: #"{"error":"invalid_grant"}"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(code: "expired", codeVerifier: "v")
            Issue.record("Expected a ComfyError, got success")
        } catch is ComfyError {
        } catch {
            Issue.record("Expected a ComfyError, got \(error)")
        }
    }

    // Scoping guard for the refresh-grant 400 mapping: `invalid_grant` on the
    // authorization-code grant means the CODE was rejected — a failed sign-in, with
    // no session to expire — so it must not reach the app as `.authExpired`, which
    // would send it straight back into the sign-in it just failed.
    @Test("exchange HTTP 400 invalid_grant is NOT remapped to .authExpired")
    func exchange400InvalidGrantIsNotAuthExpired() async throws {
        installTokenEndpoint(status: 400, body: #"{"error":"invalid_grant","error_description":"code expired"}"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(code: "expired", codeVerifier: "v")
            Issue.record("Expected a ComfyError, got success")
        } catch ComfyError.authExpired {
            Issue.record("exchange 400 invalid_grant must not surface as .authExpired")
        } catch is ComfyError {
        } catch {
            Issue.record("Expected a ComfyError, got \(error)")
        }
    }

    @Test("exchange malformed JSON throws .unknown(underlying:)")
    func exchangeMalformedJSONThrowsUnknown() async throws {
        installTokenEndpoint(status: 200, body: "not-json")
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(code: "c", codeVerifier: "v")
            Issue.record("Expected .unknown, got success")
        } catch ComfyError.unknown {
        } catch {
            Issue.record("Expected .unknown, got \(error)")
        }
    }
}

private var runOAuthIntegration: Bool {
    ProcessInfo.processInfo.environment["RUN_OAUTH_INTEGRATION"] == "1"
}

@Suite("OAuthExchange — live integration (gated)")
struct OAuthExchangeIntegrationTests {

    @Test(
        "live authorize endpoint accepts the seeded comfy-ios client and redirect URI",
        .enabled(if: runOAuthIntegration, "Requires seeded comfy-ios OAuth client — set RUN_OAUTH_INTEGRATION=1")
    )
    func liveAuthorizeEndpointAcceptsSeededClient() async throws {
        let request = ComfyCloudClient.buildAuthorizationRequest()
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(
            for: URLRequest(url: request.authorizationURL)
        )

        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode < 400, "authorize endpoint rejected the request with \(http.statusCode)")

        let body = String(data: data, encoding: .utf8) ?? ""
        #expect(!body.contains("invalid_client"))
        #expect(!body.contains("invalid_redirect_uri"))
    }
}
