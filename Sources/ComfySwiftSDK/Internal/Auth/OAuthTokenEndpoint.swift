import Foundation

/// Shared token-endpoint POST used by both `OAuthExchanger` (authorization-code
/// grant) and `OAuthTokenRefreshExecutor` (refresh grant). Both flows run the
/// identical five-step dance — form-encode the body, POST as
/// `application/x-www-form-urlencoded`, translate transport errors, check the
/// HTTP status, decode the token DTO, and build `OAuthTokenResponse` — so it
/// lives here once. Callers still own building their own query items (the two
/// grants carry different parameters).
internal enum OAuthTokenEndpoint {

    private struct TokenDTO: Codable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken  = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn    = "expires_in"
        }
    }

    /// RFC 6749 §5.2 error response. The token endpoint answers a rejected grant
    /// with HTTP 400 and this body — `invalid_grant` for a refresh token that is
    /// expired, revoked, reused, or simply unknown to the server.
    private struct TokenErrorDTO: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    /// POSTs a form-encoded token request and decodes the standard token response.
    /// - Parameter isRefreshGrant: `true` for the refresh grant, which classifies a
    ///   dead session differently from the authorization-code grant in two places:
    ///   an HTTP 400 `invalid_grant` becomes `.authExpired` (and any other 400
    ///   becomes `.unknown`, never `.network`), and an HTTP 401/403
    ///   (`ComfyError.authInvalid` from `Transport.checkStatus`) is remapped to
    ///   `.authExpired` as well. Exchange callers pass `false`: a rejected
    ///   authorization code is a failed *sign-in*, not an expired session, so
    ///   routing it to the app's re-authentication flow would only loop.
    static func post(
        queryItems: [URLQueryItem],
        session: URLSession,
        isRefreshGrant: Bool
    ) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: OAuthConfiguration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let bodyData = formURLEncoded(queryItems).data(using: .utf8) else {
            throw ComfyError.unknown(underlying: URLError(.badURL))
        }
        request.httpBody = bodyData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Transport.translate(error)
        }

        // The 400 arm has to run BEFORE `Transport.checkStatus`, whose `default:`
        // maps every unmodelled status to `.network(URLError(.badServerResponse))`.
        // For the refresh grant that is actively wrong: a permanently dead session
        // would reach the caller as a retryable "check your connection" error, and
        // the app's re-sign-in flow — which keys on `.authExpired` — is never reached.
        if isRefreshGrant, (response as? HTTPURLResponse)?.statusCode == 400 {
            throw refreshGrantRejection(from: data, redacting: secretValues(in: queryItems))
        }

        do {
            try Transport.checkStatus(response)
        } catch ComfyError.authInvalid where isRefreshGrant {
            // Defence in depth: 400 `invalid_grant` is what the production token
            // endpoint actually sends for a dead refresh token, but a proxy or CDN
            // in front of it may answer 401/403 instead.
            throw ComfyError.authExpired
        }

        let dto: TokenDTO
        do {
            dto = try JSONDecoder().decode(TokenDTO.self, from: data)
        } catch {
            throw ComfyError.unknown(underlying: error)
        }

        return OAuthTokenResponse(
            accessToken: dto.accessToken,
            refreshToken: dto.refreshToken,
            expiresIn: dto.expiresIn
        )
    }

    /// Classifies an RFC 6749 §5.2 error body returned for the refresh grant.
    ///
    /// `invalid_grant` is the one recoverable-by-re-authentication case: the refresh
    /// token is expired, revoked, reused, or unknown to the server. Every other
    /// defined code (`invalid_request`, `invalid_client`, `unauthorized_client`,
    /// `unsupported_grant_type`) reports a malformed request — a client bug — and an
    /// unparseable body is equally not something a retry fixes, so both surface as
    /// `.unknown` rather than `.network`, which would invite a useless retry loop.
    private static func refreshGrantRejection(
        from data: Data,
        redacting secrets: [String]
    ) -> ComfyError {
        guard let dto = try? JSONDecoder().decode(TokenErrorDTO.self, from: data) else {
            return .unknown(underlying: OAuthTokenEndpointError(code: nil, detail: nil))
        }
        guard dto.error != "invalid_grant" else {
            return .authExpired
        }
        // Redact BEFORE clamping: clamping first could split a secret in half and
        // leave the surviving prefix in the message.
        let detail = dto.errorDescription
            .map { redact(secrets, in: $0) }
            .map { OAuthTokenEndpointError.clamp($0, to: 200) }
        return .unknown(
            underlying: OAuthTokenEndpointError(
                code: OAuthTokenEndpointError.clamp(redact(secrets, in: dto.error), to: 64),
                detail: detail
            )
        )
    }

    /// The request values that must never survive into an error a consumer may log
    /// (NFR-S2). The 400 body has no token fields of its own per RFC 6749 §5.2, so
    /// this guards only against a server echoing back what we sent it.
    private static func secretValues(in items: [URLQueryItem]) -> [String] {
        let sensitive: Set<String> = ["refresh_token", "code", "code_verifier", "client_secret"]
        return items.compactMap { item in
            guard sensitive.contains(item.name), let value = item.value, !value.isEmpty else {
                return nil
            }
            return value
        }
    }

    private static func redact(_ secrets: [String], in text: String) -> String {
        secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
    }

    /// Serializes query items as an `application/x-www-form-urlencoded` body.
    /// Unlike `URLComponents.query` (which encodes with `.urlQueryAllowed` and
    /// leaves `+`, `&`, and `=` unescaped), this percent-encodes every character
    /// outside the RFC 3986 unreserved set, so an opaque token value — e.g. a
    /// standard-base64 `code`/`refresh_token` containing `+` — survives the
    /// round-trip instead of being decoded server-side as a space or corrupting
    /// adjacent form fields.
    private static func formURLEncoded(_ items: [URLQueryItem]) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        }
        return items
            .map { "\(encode($0.name))=\(encode($0.value ?? ""))" }
            .joined(separator: "&")
    }
}

/// The token endpoint rejected the request with an HTTP 400 that is not
/// `invalid_grant` — a client implementation bug rather than a dead session —
/// or with a 400 whose body could not be parsed as RFC 6749 §5.2.
///
/// Only the endpoint's own `error` / `error_description` fields are carried — the
/// raw body is never retained — and both are scrubbed of the request's own secret
/// values and then length-clamped, so a server that echoes back what we sent it
/// cannot leak a credential into a consumer's logs through here (NFR-S2).
struct OAuthTokenEndpointError: Error, CustomStringConvertible, LocalizedError {
    /// The RFC 6749 §5.2 `error` code, or `nil` when the body was unparseable.
    let code: String?
    /// The optional `error_description`, redacted and clamped.
    let detail: String?

    static func clamp(_ value: String, to limit: Int) -> String {
        value.count <= limit ? value : String(value.prefix(limit)) + "…"
    }

    var description: String {
        guard let code else {
            return "OAuth token endpoint returned HTTP 400 with an unparseable body"
        }
        guard let detail, !detail.isEmpty else {
            return "OAuth token endpoint returned HTTP 400 \(code)"
        }
        return "OAuth token endpoint returned HTTP 400 \(code): \(detail)"
    }

    var errorDescription: String? { description }
}
