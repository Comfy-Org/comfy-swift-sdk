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

        // Exchange lets an HTTP 401 surface as `.authInvalid`, and EVERY HTTP 400 is
        // classified by `OAuthTokenEndpoint` as `ComfyError.authCodeRejected` —
        // parseable body or not, because the 400 on this grant is itself the refusal
        // signal. A rejected authorization code is a client-side refusal, not the
        // retryable transport failure `Transport.checkStatus` would have called it,
        // and `.authCodeRejected` is the public case a consumer branches on to send
        // the user back through sign-in for a fresh code. Only the refresh grant
        // (`isRefreshGrant: true`) remaps a rejected grant to `.authExpired`: a failed
        // authorization-code exchange is a failed sign-in with no session to expire,
        // and re-running the *refresh* path on it would loop.
        return try await OAuthTokenEndpoint.post(
            queryItems: queryItems,
            session: session,
            isRefreshGrant: false
        )
    }
}
