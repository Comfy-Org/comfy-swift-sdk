import Foundation

extension ComfyAuth {

    /// Runs one full interactive "Sign in with Comfy" attempt and returns a ready, self-refreshing
    /// client.
    ///
    /// This is the one-call orchestrator for the whole authorization-code + PKCE flow: it builds the
    /// authorize request, presents it through the injected `presenter` (the app's
    /// `ASWebAuthenticationSession`), verifies the callback's `state` and extracts the code, exchanges
    /// the code for tokens, persists them through `store`, and returns a
    /// ``ComfyCloudClient`` in refreshable mode — the same client
    /// ``restoreClient(store:config:)`` produces on a later launch. The browser step is injected so
    /// the SDK never imports `AuthenticationServices`.
    ///
    /// The security-critical callback validation is performed here, not by the presenter:
    /// ``OAuthAuthorizationRequest/extractCode(fromCallback:)`` requires the callback's `state` to
    /// match the request's before the code is redeemed.
    ///
    /// - Parameters:
    ///   - presenter: The browser step — presents the authorize URL and returns the callback URL. See
    ///     ``ComfyWebAuthPresenter``.
    ///   - store: The token store the exchanged tokens are persisted to, and that the returned client
    ///     reads/writes on every refresh.
    ///   - config: The OAuth client config to authorize and exchange under. The same config is carried
    ///     through the exchange and into the returned client so the SDK-owned refresh grant's
    ///     `client_id` matches. Defaults to ``OAuthClientConfig/comfyIOS``.
    /// - Returns: A refreshable ``ComfyCloudClient`` authenticated with the freshly minted tokens.
    /// - Throws: ``ComfyError/authCancelled`` if the user dismisses the web session or the callback
    ///   carries no code; ``ComfyError/authStateMismatch`` if the callback's `state` is absent or does
    ///   not match; ``ComfyError/authInvalid`` if the token endpoint returns an empty access or
    ///   refresh token; ``ComfyError/authCodeRejected(code:detail:)`` if the token endpoint
    ///   refuses the code-for-tokens exchange (HTTP 400), whose `code` distinguishes the
    ///   `"invalid_grant"` case a fresh sign-in clears — expired, already redeemed, or
    ///   mismatched against the PKCE verifier — from the other RFC 6749 §5.2 codes, which
    ///   report a malformed request or client-configuration bug that retrying sign-in
    ///   cannot fix;
    ///   and any ``ComfyError`` the token exchange or the store's
    ///   ``ComfyTokenStore/save(_:)`` raises — all propagated unchanged.
    /// - Note: If ``ComfyTokenStore/save(_:)`` fails *after* the code has been redeemed, the error
    ///   propagates and the freshly minted tokens are dropped rather than stored. The refresh token is
    ///   then live on the server with no client record; the next ``signIn(presenter:store:config:)``
    ///   mints a new pair and the orphaned one lapses on its own expiry. The SDK does not attempt a
    ///   revocation call, so a store whose `save` can fail should treat this as a normal retry.
    public static func signIn(
        presenter: ComfyWebAuthPresenter,
        store: ComfyTokenStore,
        config: OAuthClientConfig = .comfyIOS
    ) async throws -> ComfyCloudClient {
        try await signIn(
            presenter: presenter,
            store: store,
            config: config,
            exchange: { code, codeVerifier, config in
                try await ComfyCloudClient.exchangeAuthorizationCode(
                    code, codeVerifier: codeVerifier, config: config
                )
            }
        )
    }

    /// The testable core of ``signIn(presenter:store:config:)`` with the network exchange injected.
    ///
    /// The public entry point supplies the real
    /// ``ComfyCloudClient/exchangeAuthorizationCode(_:codeVerifier:config:)``; tests inject a stub so
    /// the full orchestration can be exercised without a live token endpoint (the real static exchange
    /// builds its own `URLSession` and so isn't interceptable by the test URL protocol).
    static func signIn(
        presenter: ComfyWebAuthPresenter,
        store: ComfyTokenStore,
        config: OAuthClientConfig,
        exchange: @Sendable (String, String, OAuthClientConfig) async throws -> OAuthTokenResponse
    ) async throws -> ComfyCloudClient {
        let request = ComfyCloudClient.buildAuthorizationRequest(config: config)
        // The presenter owns only presentation; it throws `.authCancelled` on dismissal, which
        // propagates unchanged.
        let callback = try await presenter.authenticate(
            url: request.authorizationURL,
            callbackURLScheme: config.redirectScheme
        )
        // Security-critical: `.authCancelled` on a code-less callback, `.authStateMismatch` on a
        // CSRF/misconfiguration — done by the SDK, never the presenter.
        let code = try request.extractCode(fromCallback: callback)
        let tokens = try await exchange(code, request.codeVerifier, config)
        // A well-formed-but-empty token pair (malformed JSON that still decodes) would otherwise be
        // persisted as usable credentials and fail only on the first authenticated request; reject it
        // at sign-in instead so the failure surfaces here.
        guard !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty else {
            throw ComfyError.authInvalid
        }
        // Map the wire response's relative `expiresIn` to an absolute `expiresAt` at persist time, and
        // seed the returned client's expiry cache from the same value — no re-load, and no
        // force-unwrap of `restoreClient`, which would only ever be `nil` for an empty token we just
        // minted.
        let stored = ComfyStoredTokens(response: tokens, now: Date())
        try await store.save(stored)
        return ComfyCloudClient(
            credential: makeRefreshableCredential(store: store, initialExpiry: stored.expiresAt),
            config: config
        )
    }
}
