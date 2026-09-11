import Foundation
import CryptoKit

/// A client for submitting workflows to [Comfy Cloud](https://cloud.comfy.org) and streaming their results.
///
/// Construct a client with a credential, submit a ``WorkflowRequest``, then iterate the
/// ``JobEvent`` stream from ``events(for:)`` until it reaches a terminal event.
///
/// ```swift
/// let client = ComfyCloudClient(apiKey: "your-api-key")
/// let job = try await client.submit(WorkflowRequest(workflowJSON: graph))
/// for try await event in client.events(for: job) {
///     if case .complete(let output) = event { /* use output.files */ }
/// }
/// ```
///
/// The client is `Sendable` and safe to share across tasks. Cancellation is cooperative:
/// cancel the task consuming an event stream and the SDK fires a best-effort server-side
/// cancel before finishing the stream.
public final class ComfyCloudClient: Sendable {

    private static let baseURL: URL = URL(string: "https://cloud.comfy.org")!

    private let transport: Transport
    private let webSocketSession: WebSocketSession
    private let reattachCoordinator: ReattachCoordinator

    /// The Comfy Router surface — `client.models.run("bfl/flux-2-pro", input: [...])`.
    ///
    /// A different service from the workflow surface above it: Router runs a partner model by
    /// its canonical ID over one synchronous request against `https://api.comfy.org`, while
    /// ``submit(_:)`` queues a ComfyUI graph on `https://cloud.comfy.org`. The same credential
    /// authenticates both.
    public let models: RouterModels

    /// The credential this client authenticates with. Internal so tests can assert the *mode* a
    /// factory produced (e.g. that ``ComfyAuth/signIn(presenter:store:config:)`` returns an
    /// ``ComfyCredential/oauthRefreshable(tokenProvider:refreshProvider:tokenStore:expiryProvider:)``
    /// client) without a way to leak the credential across the public surface.
    let credential: ComfyCredential

    /// Creates a client authenticated with the given credential.
    ///
    /// - Parameters:
    ///   - credential: How the client authenticates each request — an API key or an OAuth token
    ///     provider. See ``ComfyCredential``.
    ///   - config: The OAuth client config the tokens were minted under. In
    ///     ``ComfyCredential/oauthRefreshable(tokenProvider:refreshProvider:tokenStore:expiryProvider:)``
    ///     mode the SDK-owned refresh grant sends this config's ``OAuthClientConfig/clientId``, which
    ///     per RFC 6749 §6 must match the client the token was issued to. Pass the same config used
    ///     with ``buildAuthorizationRequest(config:)`` / ``exchangeAuthorizationCode(_:codeVerifier:config:)``
    ///     (available as ``OAuthAuthorizationRequest/config``). Defaults to ``OAuthClientConfig/comfyIOS``;
    ///     ignored for non-refreshable credentials.
    ///   - routerBaseURL: The host ``models`` posts model runs to. Defaults to
    ///     ``RouterModels/defaultBaseURL`` (`https://api.comfy.org`); override it to point the
    ///     Router surface at a staging host or a test stub. It does **not** move the workflow
    ///     surface, which stays on `https://cloud.comfy.org`.
    public init(
        credential: ComfyCredential,
        config: OAuthClientConfig = .comfyIOS,
        routerBaseURL: URL = RouterModels.defaultBaseURL
    ) {
        self.credential = credential
        let session = URLSession(configuration: ComfySDKInfo.sessionConfiguration())
        let transport = Transport(
            session: session,
            baseURL: Self.baseURL,
            credential: credential,
            oauthConfig: config
        )
        self.transport = transport
        self.webSocketSession = WebSocketSession(
            session: session,
            baseURL: Self.baseURL,
            credential: credential,
            transport: transport
        )
        self.reattachCoordinator = ReattachCoordinator(transport: transport)
        // Shares the session — and so the `X-Comfy-Client` header — and the transport, which is
        // where credential injection and the OAuth refresh live. Only the base URL differs.
        self.models = RouterModels(
            baseURL: routerBaseURL,
            transport: RouterTransport(
                session: session,
                baseURL: routerBaseURL,
                transport: transport
            )
        )
    }

    /// Creates a client authenticated with an API key.
    ///
    /// Equivalent to ``init(credential:)`` with ``ComfyCredential/apiKey(_:)``.
    ///
    /// - Parameter apiKey: The Comfy Cloud API key. Held privately; never logged or exposed.
    public convenience init(apiKey: String) {
        self.init(credential: .apiKey(apiKey))
    }

    /// Submits a workflow to Comfy Cloud and returns a handle for streaming its lifecycle.
    ///
    /// The returned ``JobHandle`` is consumed by ``events(for:)`` to observe the job as it runs.
    /// Persist ``JobHandle/id`` if you need to ``reattach(promptId:hasEmittedFinalizing:)`` after
    /// the app is relaunched.
    ///
    /// - Parameter request: The workflow graph and inputs to run. The SDK posts
    ///   ``WorkflowRequest/workflowJSON`` verbatim and does not validate the graph.
    /// - Returns: A ``JobHandle`` identifying the queued job.
    /// - Throws: ``ComfyError`` — `.authInvalid` if the credential is rejected,
    ///   `.offline` / `.timeout` / `.network` on transport failure, or `.serverRejected`
    ///   if Comfy Cloud refuses the workflow.
    public func submit(_ request: WorkflowRequest) async throws -> JobHandle {
        try await transport.submitJob(request)
    }

    /// Returns a cold stream of lifecycle events for a submitted job.
    ///
    /// The WebSocket connection opens when you first iterate the returned stream, which yields
    /// ``JobEvent`` values in order until terminating with `.complete`, `.failed`, or `.cancelled`.
    /// Cancelling the consuming task fires a best-effort server-side cancel and yields a final
    /// `.cancelled` event.
    ///
    /// - Parameter handle: A handle returned by ``submit(_:)``.
    /// - Returns: An `AsyncThrowingStream` of ``JobEvent``. Every error thrown during iteration is
    ///   a ``ComfyError`` (the stream is typed as `Error` only because typed `AsyncThrowingStream`
    ///   throws require a newer OS than this package targets).
    public func events(for handle: JobHandle) -> AsyncThrowingStream<JobEvent, Error> {
        webSocketSession.eventStream(for: handle)
    }

    /// Resumes a job's event stream after a network drop.
    ///
    /// Issues a single catch-up request to recover the job's current state, synthesizes the
    /// events needed to bring your state machine up to date, then continues yielding ``JobEvent``
    /// values until the job terminates. If the job has already finished, the stream emits exactly
    /// one terminal event and closes.
    ///
    /// - Parameters:
    ///   - handle: A handle for the in-flight job, from ``submit(_:)``.
    ///   - hasEmittedFinalizing: Pass `true` if your UI already showed a finalizing state for this
    ///     job, to suppress a duplicate `.finalizing` event on resume. Defaults to `false`.
    /// - Returns: An `AsyncThrowingStream` of ``JobEvent``; errors thrown during iteration are
    ///   ``ComfyError``.
    public func reattach(
        to handle: JobHandle,
        hasEmittedFinalizing: Bool = false
    ) -> AsyncThrowingStream<JobEvent, Error> {
        reattachCoordinator.reattach(to: handle, hasEmittedFinalizing: hasEmittedFinalizing)
    }

    /// Resumes a job's event stream by its opaque prompt id, for resuming after an app relaunch.
    ///
    /// Behaves like ``reattach(to:hasEmittedFinalizing:)`` but takes the id string from a persisted
    /// ``JobHandle/id``, so callers that stored the id across a process restart can resume without
    /// reconstructing a handle.
    ///
    /// - Parameters:
    ///   - promptId: The opaque id from a prior ``submit(_:)``, as exposed by ``JobHandle/id``.
    ///   - hasEmittedFinalizing: Pass `true` if your UI already showed a finalizing state for this
    ///     job, to suppress a duplicate `.finalizing` event on resume. Defaults to `false`.
    /// - Returns: An `AsyncThrowingStream` of ``JobEvent``; errors thrown during iteration are
    ///   ``ComfyError``.
    public func reattach(
        promptId: String,
        hasEmittedFinalizing: Bool = false
    ) -> AsyncThrowingStream<JobEvent, Error> {
        let handle = JobHandle(id: promptId)
        return reattachCoordinator.reattach(
            to: handle,
            hasEmittedFinalizing: hasEmittedFinalizing
        )
    }

    /// Validates the credential with a lightweight authenticated round-trip.
    ///
    /// Performs a single authenticated request and returns on success. In OAuth mode the token
    /// provider is invoked first. Useful for confirming a freshly entered API key before storing it.
    ///
    /// - Throws: ``ComfyError`` — `.authInvalid` on a `401`/`403` (or a failing OAuth token
    ///   provider), or `.network` / `.offline` / `.timeout` / `.unknown` on other failures.
    public func validate() async throws {
        try await transport.validateAuth()
    }

    /// Detaches the live event stream for a job without cancelling the job.
    ///
    /// Stops consuming the WebSocket stream for `jobId` while leaving the cloud-side job running —
    /// unlike cancelling the consuming task, which fires a server-side cancel. The detached stream's
    /// consumer sees its loop end normally, with no thrown error. No-op if no stream is registered
    /// for `jobId`.
    ///
    /// - Parameter jobId: The id of the job whose live stream should be detached.
    public func detachEvents(jobId: String) {
        webSocketSession.detachStream(jobId: jobId)
    }

    /// The custom URL scheme the first-party Comfy iOS app uses for the OAuth callback.
    ///
    /// This is the ``OAuthClientConfig/comfyIOS`` default. Apps that supply their own
    /// ``OAuthClientConfig`` should use their config's ``OAuthClientConfig/redirectScheme``
    /// as the `ASWebAuthenticationSession` callback scheme instead.
    public static let oauthCallbackScheme: String = OAuthClientConfig.comfyIOS.redirectScheme

    /// Builds the material for one "Sign in with Comfy" authorization attempt.
    ///
    /// Mints a fresh PKCE code verifier and S256 challenge, a `state` nonce, and the fully-formed
    /// authorize URL. Open ``OAuthAuthorizationRequest/authorizationURL`` in an
    /// `ASWebAuthenticationSession`, then redeem the returned code with
    /// ``exchangeAuthorizationCode(_:codeVerifier:config:)``.
    ///
    /// - Parameter config: The OAuth client parameters (client id, redirect URI, scopes) to
    ///   build the request for. Defaults to ``OAuthClientConfig/comfyIOS``.
    /// - Returns: An ``OAuthAuthorizationRequest`` carrying the authorize URL, `state`, and the
    ///   `codeVerifier` to retain for the token exchange. The verifier and state are secrets — do
    ///   not log them.
    public static func buildAuthorizationRequest(
        config: OAuthClientConfig = .comfyIOS
    ) -> OAuthAuthorizationRequest {
        var rng = SystemRandomNumberGenerator()

        let rawBytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        let codeVerifier = base64URLEncode(Data(rawBytes))

        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        let codeChallenge = base64URLEncode(Data(digest))

        let stateBytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        let state = base64URLEncode(Data(stateBytes))

        guard var components = URLComponents(
            url: OAuthConfiguration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        ) else {
            fatalError("OAuthConfiguration.authorizationEndpoint is not a parseable URL")
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: OAuthConfiguration.pkceCodeChallengeMethod),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "resource", value: OAuthConfiguration.resourceParameter),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
        ]
        guard let url = components.url else {
            fatalError("OAuthConfiguration produced an invalid authorize URL")
        }

        return OAuthAuthorizationRequest(
            authorizationURL: url,
            state: state,
            codeVerifier: codeVerifier,
            config: config
        )
    }

    /// Redeems an authorization code for an OAuth token pair.
    ///
    /// Call after the web-session callback returns a code, passing the `codeVerifier` from the
    /// matching ``buildAuthorizationRequest(config:)``. Persist the returned tokens (for example,
    /// in the Keychain) and construct an OAuth-mode client with ``ComfyCredential`` — passing the
    /// same config to ``init(credential:config:)`` so the SDK-owned refresh grant matches.
    ///
    /// - Parameters:
    ///   - code: The authorization code from the callback URL.
    ///   - codeVerifier: The PKCE verifier from the originating
    ///     ``buildAuthorizationRequest(config:)``.
    ///   - config: The OAuth client parameters (client id, redirect URI) to redeem against. Must
    ///     match the config the authorization request was built with — pass the request's
    ///     ``OAuthAuthorizationRequest/config`` to keep them in lockstep. Defaults to
    ///     ``OAuthClientConfig/comfyIOS``.
    /// - Returns: An ``OAuthTokenResponse`` with the access and refresh tokens.
    /// - Throws: ``ComfyError`` on network failure or a rejected exchange.
    public static func exchangeAuthorizationCode(
        _ code: String,
        codeVerifier: String,
        config: OAuthClientConfig = .comfyIOS
    ) async throws -> OAuthTokenResponse {
        let exchanger = OAuthExchanger(session: URLSession(configuration: ComfySDKInfo.sessionConfiguration()))
        return try await exchanger.exchange(code: code, codeVerifier: codeVerifier, config: config)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
