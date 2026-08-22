//
//  ASWebAuthPresenter.swift
//  ComfyAuthKit
//
//  The batteries-included ``ComfyWebAuthPresenter`` — a default adapter over
//  `ASWebAuthenticationSession` so apps don't have to hand-write the
//  present-and-retain + cancellation-mapping boilerplate. Lives in ComfyAuthKit
//  (not the core SDK) because it imports `AuthenticationServices`, which the
//  core SDK's Foundation-only import boundary forbids. Apps that want full
//  control skip ComfyAuthKit and conform their own type to
//  ``ComfyWebAuthPresenter`` instead.
//
//  Ported from the Comfy Go iOS app's OAuthCoordinator, narrowed to the single
//  responsibility ``ComfyWebAuthPresenter`` asks for: present the authorize URL,
//  return the callback URL unchanged, and let the SDK do the `state`
//  verification + code extraction. This type never parses the callback.
//

import AuthenticationServices
import ComfySwiftSDK
import Foundation

/// A ready-to-use ``ComfyWebAuthPresenter`` backed by `ASWebAuthenticationSession`.
///
/// Hand an instance to ``ComfyAuth/signIn(presenter:store:config:)`` and it presents the authorize
/// URL in the system web sheet, retains the session until the callback fires (an unretained
/// `ASWebAuthenticationSession` silently cancels mid-flow), and maps a user dismissal onto
/// ``ComfyError/authCancelled`` — the stable error the SDK propagates so callers distinguish "the
/// user backed out" from a genuine failure.
///
/// `@MainActor` because `ASWebAuthenticationSession.start()` must run on the main thread and the
/// retained session is UI state.
///
/// - Note: `prefersEphemeralWebBrowserSession` is `false` so the sheet reuses the system browser's
///   saved credentials (e.g. an existing Google session) — the desired first-run UX.
@MainActor
public final class ASWebAuthPresenter: NSObject, ComfyWebAuthPresenter, ASWebAuthenticationPresentationContextProviding {

    /// The in-flight web session — retained to prevent ARC from releasing it before the completion
    /// handler fires (an unretained session silently cancels mid-flow).
    private var session: ASWebAuthenticationSession?

    /// An optional explicit presentation anchor. When `nil`, ``presentationAnchor(for:)`` hands back
    /// a fresh `ASPresentationAnchor()`, which on iOS 17+/macOS 14+ auto-locates the key window.
    private let anchor: ASPresentationAnchor?

    /// Creates a presenter.
    ///
    /// - Parameter anchor: An explicit window to present from. Defaults to `nil`, which lets the
    ///   system auto-locate the app's key window (iOS 17+/macOS 14+). Pass an anchor when the app
    ///   has multiple scenes/windows and the automatic choice is not the right one.
    public init(anchor: ASPresentationAnchor? = nil) {
        self.anchor = anchor
        super.init()
    }

    /// Failures raised by the presenter itself, as opposed to the OAuth callback (which maps onto
    /// ``ComfyError/authCancelled`` or propagates its own error via ``mapCallback(url:error:)``).
    public enum PresentationError: Error, Equatable {
        /// `ASWebAuthenticationSession.start()` returned `false` — no valid presentation anchor/key
        /// window, or another session is already in flight. The sheet never appeared, so the
        /// completion handler will never fire; the caller is failed with this instead of hanging.
        case sessionStartFailed
        /// ``authenticate(url:callbackURLScheme:)`` was called while a prior session is still in
        /// flight. A single presenter drives one sheet at a time; overlapping calls are rejected
        /// rather than silently dropping the earlier session's only strong reference.
        case alreadyPresenting
    }

    /// Presents `url` in an `ASWebAuthenticationSession` and returns the callback URL unchanged for
    /// the SDK to validate.
    ///
    /// - Throws: ``ComfyError/authCancelled`` when the user dismisses the sheet;
    ///   ``PresentationError/alreadyPresenting`` if another sheet is already in flight;
    ///   ``PresentationError/sessionStartFailed`` if the system refuses to present; any other
    ///   transport-level error as-is.
    public func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        // Reject re-entrant calls: overwriting `session` would drop the in-flight session's only
        // strong reference, silently cancelling that OAuth flow and leaking its continuation.
        guard session == nil else {
            throw PresentationError.alreadyPresenting
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: callbackURLScheme
                ) { [weak self] callbackURL, error in
                    // Release the retained session now that the callback has fired.
                    Task { @MainActor [weak self] in
                        self?.session = nil
                    }
                    continuation.resume(with: Result { try Self.mapCallback(url: callbackURL, error: error) })
                }
                session.presentationContextProvider = self
                // false: reuse the system browser's saved credentials — the desired first-run UX.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session // retain until the callback fires
                guard session.start() else {
                    // start() returned false: the sheet never presented and the completion handler
                    // will never fire, so resume here (and drop the retained session) instead of
                    // hanging the caller forever on an unresumed continuation.
                    self.session = nil
                    continuation.resume(throwing: PresentationError.sessionStartFailed)
                    return
                }
            }
        } onCancel: {
            // Swift task cancellation: tear down the presented sheet so it doesn't linger. cancel()
            // fires the completion handler with `.canceledLogin`, resuming the continuation as
            // ``ComfyError/authCancelled``.
            Task { @MainActor [weak self] in
                self?.session?.cancel()
            }
        }
    }

    /// Maps an `ASWebAuthenticationSession` completion `(url, error)` pair onto the SDK contract:
    /// a `.canceledLogin` dismissal (or a bare no-url/no-error callback) becomes
    /// ``ComfyError/authCancelled``, any other error propagates unchanged, and a delivered callback
    /// URL is returned as-is.
    ///
    /// Extracted from the completion handler and `nonisolated` so the cancellation mapping is unit
    /// testable without presenting a real session.
    nonisolated static func mapCallback(url: URL?, error: Error?) throws -> URL {
        if let error {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                throw ComfyError.authCancelled
            }
            throw error
        }
        guard let url else {
            // No error and no URL is not a documented outcome; treat it as a dismissal rather than
            // returning a bogus URL, so the caller sees the same stable cancellation error.
            throw ComfyError.authCancelled
        }
        return url
    }

    /// The window to anchor the web sheet to. Returns the injected ``anchor`` when set, otherwise a
    /// fresh `ASPresentationAnchor()` — on iOS 17+/macOS 14+ the system auto-locates the key window
    /// from an unattached anchor.
    ///
    /// `nonisolated` to satisfy the (non-isolated) `ASWebAuthenticationPresentationContextProviding`
    /// requirement; `MainActor.assumeIsolated` reads the main-actor state — AuthenticationServices
    /// always invokes this on the main thread, and both `anchor` and `ASPresentationAnchor()`
    /// (a `UIWindow`/`NSWindow`) are main-actor bound.
    public nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            anchor ?? ASPresentationAnchor()
        }
    }
}
