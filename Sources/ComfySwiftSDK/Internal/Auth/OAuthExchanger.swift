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

        // Exchange lets an HTTP 401 surface as `.authInvalid` and leaves a 400 to
        // `Transport.checkStatus` (`isRefreshGrant: false`); only the refresh grant
        // remaps a rejected grant to `.authExpired`. A failed authorization-code
        // exchange is a failed sign-in, and re-running sign-in on it would loop.
        return try await OAuthTokenEndpoint.post(
            queryItems: queryItems,
            session: session,
            isRefreshGrant: false
        )
    }
}
