import Foundation

internal actor OAuthTokenRefreshExecutor {

    private nonisolated let session: URLSession

    internal init(session: URLSession) {
        self.session = session
    }

    internal func refresh(
        using refreshToken: String,
        clientId: String = OAuthClientConfig.comfyIOS.clientId
    ) async throws -> OAuthTokenResponse {
        let queryItems = [
            URLQueryItem(name: "grant_type",    value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            // Per RFC 6749 §6 the refresh grant must carry the same client the token was issued to,
            // so this is threaded from the client's OAuthClientConfig (Transport.oauthConfig) rather
            // than pinned to comfy-ios — a token minted under a custom config would otherwise be
            // rejected on refresh, silently logging the app out at access-token expiry.
            URLQueryItem(name: "client_id",     value: clientId),
            URLQueryItem(name: "resource",      value: OAuthConfiguration.resourceParameter),
        ]

        // A rejected refresh token must drive re-authentication, not a retry. The
        // production token endpoint reports that as an RFC 6749 §5.2 HTTP 400
        // `invalid_grant`; `isRefreshGrant` is what maps it — and a 401/403 — to
        // `.authExpired`, instead of letting a 400 fall through to `.network`.
        return try await OAuthTokenEndpoint.post(
            queryItems: queryItems,
            session: session,
            isRefreshGrant: true
        )
    }
}
