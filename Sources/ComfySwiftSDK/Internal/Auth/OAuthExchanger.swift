import Foundation

internal actor OAuthExchanger {

    private nonisolated let session: URLSession

    internal init(session: URLSession) {
        self.session = session
    }

    internal func exchange(
        code: String,
        codeVerifier: String,
        config: OAuthClientConfig = .comfyIOS
    ) async throws -> OAuthTokenResponse {
        let queryItems = [
            URLQueryItem(name: "grant_type",    value: "authorization_code"),
            URLQueryItem(name: "code",          value: code),
            URLQueryItem(name: "redirect_uri",  value: config.redirectURI),
            URLQueryItem(name: "client_id",     value: config.clientId),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "resource",      value: OAuthConfiguration.resourceParameter),
        ]

        // Exchange lets an HTTP 401 surface as `.authInvalid`, and its HTTP 400 is
        // classified by `OAuthTokenEndpoint` as `.unknown(OAuthTokenEndpointError)` —
        // a rejected authorization code is a client-side refusal, not the retryable
        // transport failure `Transport.checkStatus` would have called it. Only the
        // refresh grant (`isRefreshGrant: true`) remaps a rejected grant to
        // `.authExpired`: a failed authorization-code exchange is a failed sign-in
        // with no session to expire, and re-running sign-in on it would loop.
        return try await OAuthTokenEndpoint.post(
            queryItems: queryItems,
            session: session,
            isRefreshGrant: false
        )
    }
}
