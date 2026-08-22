//
//  ASWebAuthPresenterTests.swift
//  ComfyAuthKitTests
//
//  Exercises ASWebAuthPresenter's conformance/compile surface and the
//  cancellation mapping in isolation. ASWebAuthenticationSession itself cannot
//  be faked (concrete system class, no injectable seam), so the present-and-
//  retain path is left to on-device integration; the security-relevant piece —
//  mapping a `.canceledLogin` dismissal onto ComfyError.authCancelled — is
//  extracted into `mapCallback(url:error:)` and tested directly here.
//

import AuthenticationServices
import Testing
import Foundation
import ComfySwiftSDK
@testable import ComfyAuthKit

@Suite("ASWebAuthPresenter")
struct ASWebAuthPresenterTests {

    /// A distinct error type used to prove non-cancellation errors propagate unchanged.
    private struct SomeTransportError: Error {}

    @MainActor
    @Test("conforms to ComfyWebAuthPresenter and ASWebAuthenticationPresentationContextProviding")
    func conformsAndCompiles() {
        let presenter = ASWebAuthPresenter()
        // Erasing to the SDK protocol proves the conformance the SDK actually consumes.
        let asPresenter: any ComfyWebAuthPresenter = presenter
        _ = asPresenter
        // And the context-provider conformance the session needs.
        let asProvider: any ASWebAuthenticationPresentationContextProviding = presenter
        _ = asProvider
    }

    @Test("maps a .canceledLogin dismissal to ComfyError.authCancelled")
    func mapsCanceledLoginToAuthCancelled() {
        let cancelError = ASWebAuthenticationSessionError(.canceledLogin)
        do {
            _ = try ASWebAuthPresenter.mapCallback(url: nil, error: cancelError)
            Issue.record("expected ComfyError.authCancelled to be thrown")
        } catch ComfyError.authCancelled {
            // pass
        } catch {
            Issue.record("expected ComfyError.authCancelled, got \(error)")
        }
    }

    @Test("propagates a non-cancellation error unchanged")
    func propagatesOtherErrors() {
        do {
            _ = try ASWebAuthPresenter.mapCallback(url: nil, error: SomeTransportError())
            Issue.record("expected the transport error to be rethrown")
        } catch is SomeTransportError {
            // pass — a genuine failure is not swallowed into authCancelled
        } catch {
            Issue.record("expected SomeTransportError, got \(error)")
        }
    }

    @Test("treats a bare no-url/no-error callback as a cancellation")
    func treatsEmptyCallbackAsCancellation() {
        do {
            _ = try ASWebAuthPresenter.mapCallback(url: nil, error: nil)
            Issue.record("expected ComfyError.authCancelled to be thrown")
        } catch ComfyError.authCancelled {
            // pass
        } catch {
            Issue.record("expected ComfyError.authCancelled, got \(error)")
        }
    }

    @Test("returns a delivered callback URL unchanged")
    func returnsCallbackURL() throws {
        let callback = URL(string: "comfy://callback?code=abc&state=xyz")!
        let result = try ASWebAuthPresenter.mapCallback(url: callback, error: nil)
        #expect(result == callback)
    }

    @Test("an error takes precedence even when a callback URL is also delivered")
    func errorTakesPrecedenceOverURL() {
        // A non-nil error must win: an ASWebAuthenticationSession callback with both set is a
        // failure, and returning the URL would let the SDK proceed on a failed session.
        do {
            _ = try ASWebAuthPresenter.mapCallback(
                url: URL(string: "comfy://callback")!,
                error: ASWebAuthenticationSessionError(.canceledLogin)
            )
            Issue.record("expected the error to take precedence")
        } catch ComfyError.authCancelled {
            // pass
        } catch {
            Issue.record("expected ComfyError.authCancelled, got \(error)")
        }
    }
}
