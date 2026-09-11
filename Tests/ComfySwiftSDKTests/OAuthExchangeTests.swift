import Testing
import Foundation
import CryptoKit
@testable import ComfySwiftSDK

@Suite("OAuthExchange — AC1/AC2/AC5", .serialized)
struct OAuthExchangeTests {

    private static let base64URLAlphabet = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

    // Production-shaped secrets for the 400-classification tests below: opaque and
    // long, matching what the flow really sends — `buildAuthorizationRequest` derives
    // the verifier from 32 random bytes (43 base64url characters). `redact` is a
    // substring replacement over the values the request actually sent, so these are
    // long enough to clear its minimum-length floor and exercise the redaction path
    // for real. The floor itself — what keeps a one-letter stand-in from being struck
    // out of the endpoint's own `invalid_grant` code — is pinned separately by
    // `exchange400ShortSecretsDoNotCorruptTheCode`.
    private static let realisticCode = "test-code-not-a-real-authorization-codeaaaa"
    private static let realisticVerifier = "test-verifier-not-a-real-code-verifierbbbbb"

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
    // would send it straight back into the sign-in it just failed. Pinned in BOTH
    // directions: the concrete case it MUST be, not merely a case it must not be.
    @Test("exchange HTTP 400 invalid_grant surfaces .authCodeRejected, not .authExpired")
    func exchange400InvalidGrantIsNotAuthExpired() async throws {
        installTokenEndpoint(status: 400, body: #"{"error":"invalid_grant","error_description":"code expired"}"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(
                code: Self.realisticCode,
                codeVerifier: Self.realisticVerifier
            )
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.authExpired {
            Issue.record("exchange 400 invalid_grant must not surface as .authExpired")
        } catch ComfyError.authCodeRejected(let code, let detail) {
            #expect(code == "invalid_grant")
            #expect(detail == "code expired")
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
        }
    }

    // The regression this file exists to hold: before the exchange grant entered the
    // typed 400 path it fell through to `Transport.checkStatus`, whose `default:` arm
    // calls every unmodelled status `.network(URLError(.badServerResponse))` — a
    // transient, retryable transport failure. A rejected authorization code is the
    // opposite: retrying it can only fail again, so a consumer branching on
    // `.network` would spin. Asserted on the raw endpoint so it covers the grant
    // rather than one caller.
    @Test("exchange HTTP 400 invalid_grant is never classified .network")
    func exchange400InvalidGrantIsNotNetwork() async throws {
        installTokenEndpoint(status: 400, body: #"{"error":"invalid_grant","error_description":"code expired"}"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(
                code: Self.realisticCode,
                codeVerifier: Self.realisticVerifier
            )
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.network(let underlying) {
            Issue.record("exchange 400 invalid_grant must not surface as .network(\(underlying))")
        } catch ComfyError.authCodeRejected {
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
        }
    }

    // Every OTHER RFC 6749 §5.2 code on the exchange grant lands in the same place —
    // `.authCodeRejected` carrying the endpoint's own code — so the classification
    // does not depend on which rejection the server picked.
    @Test("exchange HTTP 400 invalid_request surfaces .authCodeRejected carrying the code")
    func exchange400InvalidRequestSurfacesAuthCodeRejected() async throws {
        installTokenEndpoint(status: 400, body: #"{"error":"invalid_request","error_description":"missing code_verifier"}"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(
                code: Self.realisticCode,
                codeVerifier: Self.realisticVerifier
            )
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.authCodeRejected(let code, _) {
            #expect(code == "invalid_request")
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
        }
    }

    // An unparseable 400 body is still a refusal, not a transport failure, and on
    // this grant the HTTP 400 is itself the refusal signal — there is no
    // consumer-meaningful difference between "refused with a body we could not parse"
    // and "refused". So it is the SAME case as every other exchange 400, with both
    // payload fields `nil` because there was nothing to read: never `.unknown`, never
    // `.network`.
    @Test("exchange HTTP 400 with an unparseable body surfaces .authCodeRejected(nil, nil)")
    func exchange400UnparseableBodySurfacesAuthCodeRejected() async throws {
        installTokenEndpoint(status: 400, body: "<html>bad request</html>")
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(
                code: Self.realisticCode,
                codeVerifier: Self.realisticVerifier
            )
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.authCodeRejected(let code, let detail) {
            #expect(code == nil)
            #expect(detail == nil)
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
        }
    }

    // The public `code` is normalized — trimmed and lowercased — so a consumer can
    // branch on the RFC 6749 §5.2 value with `==` instead of re-implementing the
    // case/whitespace tolerance the SDK already applies to the refresh grant's own
    // `invalid_grant` match. A proxy that re-cases or pads the value is off the happy
    // path; it must not cost the consumer the branch.
    @Test("exchange HTTP 400 normalizes a re-cased, padded code before reporting it")
    func exchange400NormalizesTheReportedCode() async throws {
        installTokenEndpoint(
            status: 400,
            body: #"{"error":"  INVALID_GRANT \n","error_description":"authorization code expired"}"#
        )
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(
                code: Self.realisticCode,
                codeVerifier: Self.realisticVerifier
            )
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.authCodeRejected(let code, let detail) {
            #expect(code == "invalid_grant")
            #expect(detail == "authorization code expired")
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
        }
    }

    // NFR-S2 on the exchange half: the 400 arm now runs for this grant too, so the
    // request's own secrets must not survive into an error a consumer may log — and
    // for the exchange grant those are `code` and `code_verifier`, which the refresh
    // grant never sends.
    @Test("exchange HTTP 400 redacts an echoed code and code_verifier")
    func exchange400RedactsEchoedSecrets() async throws {
        installTokenEndpoint(
            status: 400,
            body: #"{"error":"invalid_grant","error_description":"code test-code-not-a-real-authorization-codeaaaa with verifier test-verifier-not-a-real-code-verifierbbbbb was rejected"}"#
        )
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(
                code: Self.realisticCode,
                codeVerifier: Self.realisticVerifier
            )
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.authCodeRejected(_, let rawDetail) {
            let detail = try #require(rawDetail)
            #expect(!detail.contains(Self.realisticCode))
            #expect(!detail.contains(Self.realisticVerifier))
            #expect(detail.contains("<redacted>"))
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
        }
    }

    // The length floor is scoped to the RFC code, and this pins both halves of that
    // split with one request. Matching is unanchored, so without a floor a
    // one-character `code_verifier` is struck out of the endpoint's own code —
    // `in<redacted>alid_grant` — destroying the one machine-readable field a consumer
    // can branch on. `error_description` is free text, where the trade runs the other
    // way: striking a word out of it is harmless noise, and leaving a short
    // credential in it is not, so it takes no floor.
    @Test("exchange HTTP 400 floors redaction in the RFC code but not in the description")
    func exchange400ShortSecretsDoNotCorruptTheCode() async throws {
        installTokenEndpoint(status: 400, body: #"{"error":"invalid_grant","error_description":"code expired"}"#)
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(code: "c", codeVerifier: "v")
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.authCodeRejected(let code, let detail) {
            #expect(code == "invalid_grant")
            #expect(detail == "<redacted>ode expired")
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
        }
    }

    // NFR-S2 for a credential too short to clear the RFC code's floor: it still must
    // not survive in `error_description`, which is where a server can actually echo
    // one back. Seven characters — one under the floor.
    @Test("exchange HTTP 400 redacts a short echoed credential from the description")
    func exchange400RedactsShortSecretFromDetail() async throws {
        installTokenEndpoint(
            status: 400,
            body: #"{"error":"invalid_grant","error_description":"the code abc1234 with verifier xyz9876 was rejected"}"#
        )
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(code: "abc1234", codeVerifier: "xyz9876")
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.authCodeRejected(let code, let rawDetail) {
            let detail = try #require(rawDetail)
            #expect(!detail.contains("abc1234"), "NFR-S2 VIOLATION: short code survived into \(detail)")
            #expect(!detail.contains("xyz9876"), "NFR-S2 VIOLATION: short verifier survived into \(detail)")
            #expect(detail.contains("<redacted>"))
            // …and the floor still protects the code these secrets do not appear in.
            #expect(code == "invalid_grant")
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
        }
    }

    // NFR-S2 against a credential broken up by separators rather than echoed whole.
    // `sanitize` collapses a newline or tab to a single space instead of deleting it,
    // so a redaction that only looks for the exact value leaves `ab cd` behind for
    // `abcd` — still the credential, one keystroke from reversible. The assertion is
    // therefore made on the separator-stripped text, not just the raw detail.
    @Test("exchange HTTP 400 redacts a credential split by a newline or a tab")
    func exchange400RedactsSeparatorSplitSecrets() async throws {
        installTokenEndpoint(
            status: 400,
            body: #"""
            {"error":"invalid_grant","error_description":"verifier test-verifier-not\n-a-real-code-verifierbbbbb and code test-code-not\t-a-real-authorization-codeaaaa were rejected"}
            """#
        )
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(
                code: Self.realisticCode,
                codeVerifier: Self.realisticVerifier
            )
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.authCodeRejected(_, let rawDetail) {
            let detail = try #require(rawDetail)
            let rejoined = detail.components(separatedBy: .whitespacesAndNewlines).joined()
            #expect(
                !rejoined.contains(Self.realisticVerifier),
                "NFR-S2 VIOLATION: split code_verifier is still reversible from \(detail)"
            )
            #expect(
                !rejoined.contains(Self.realisticCode),
                "NFR-S2 VIOLATION: split code is still reversible from \(detail)"
            )
            #expect(detail.contains("<redacted>"))
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
        }
    }

    // NFR-S2 against the evasion a single pre-sanitize redaction misses: a server
    // that echoes the secret with Unicode format scalars spliced through it. A soft
    // hyphen is invisible when rendered and is category Cf, so `sanitize` strips it —
    // an exact match run only beforehand finds nothing, and sanitizing then
    // reassembles the plaintext credential into `detail`.
    @Test("exchange HTTP 400 redacts a secret echoed with invisible characters spliced in")
    func exchange400RedactsSecretSplicedWithFormatCharacters() async throws {
        let spliced = Self.realisticVerifier.replacingOccurrences(
            of: "verifier",
            with: "ver\u{00ad}ifier"
        )
        installTokenEndpoint(
            status: 400,
            body: #"{"error":"invalid_grant","error_description":"verifier \#(spliced) was rejected"}"#
        )
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(
                code: Self.realisticCode,
                codeVerifier: Self.realisticVerifier
            )
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.authCodeRejected(_, let rawDetail) {
            let detail = try #require(rawDetail)
            #expect(
                !detail.contains(Self.realisticVerifier),
                "NFR-S2 VIOLATION: code_verifier reassembled by sanitize into \(detail)"
            )
            #expect(detail.contains("<redacted>"))
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
        }
    }

    // Ordering guard for the normalization added alongside `.authCodeRejected`:
    // `scrub` runs FIRST and `trimmed/lowercased` second. `redact` matches the values
    // the request actually sent, so lowercasing the endpoint's string first would
    // stop it matching a mixed-case secret the server echoed back — and the
    // credential would land in the public `code` of an error consumers log. Asserted
    // on `code`, the field the normalization touches.
    @Test("exchange HTTP 400 redacts an echoed mixed-case secret before normalizing")
    func exchange400RedactsMixedCaseSecretBeforeNormalizing() async throws {
        let mixedCaseCode = "Test-Code-NOT-a-Real-Authorization-CodeAaAa"
        installTokenEndpoint(
            status: 400,
            body: #"{"error":"\#(mixedCaseCode)"}"#
        )
        defer { TestURLProtocol.uninstall() }

        do {
            _ = try await makeExchanger().exchange(
                code: mixedCaseCode,
                codeVerifier: Self.realisticVerifier
            )
            Issue.record("Expected .authCodeRejected, got success")
        } catch ComfyError.authCodeRejected(let rawCode, _) {
            let code = try #require(rawCode)
            #expect(
                !code.contains(mixedCaseCode.lowercased()),
                "NFR-S2 VIOLATION: normalizing before redacting leaked the code as \(code)"
            )
            #expect(code == "<redacted>")
        } catch {
            Issue.record("Expected .authCodeRejected, got \(error)")
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
