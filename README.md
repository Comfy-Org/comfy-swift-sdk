<div align="center">

<img src="assets/logo.svg" alt="Comfy Cloud" width="130"/>

<h1>comfy-swift-sdk</h1>

<p>
  <strong>The Swift client for <a href="https://cloud.comfy.org">Comfy Cloud</a>.</strong><br/>
  Submit a workflow, stream its events, get your outputs — in a few lines of <code>async</code>/<code>await</code>.
</p>

</div>

<p align="center">
  <a href="#"><img src="https://img.shields.io/badge/Swift-5.9-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift 5.9"></a>
  <a href="#"><img src="https://img.shields.io/badge/Platforms-iOS%2017%20%7C%20macOS%2014-blue?style=for-the-badge&logo=apple&logoColor=white" alt="Platforms"></a>
  <a href="#"><img src="https://img.shields.io/badge/SwiftPM-compatible-brightgreen?style=for-the-badge&logo=swift&logoColor=white" alt="SwiftPM"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-lightgrey?style=for-the-badge" alt="License: Apache 2.0"></a>
  <a href="https://cloud.comfy.org"><img src="https://img.shields.io/badge/Comfy_Cloud-cloud.comfy.org-211927?style=for-the-badge" alt="Comfy Cloud"></a>
</p>

---

A thin, dependency-free Swift client for the [Comfy Cloud](https://cloud.comfy.org) API. You hand it a
ComfyUI workflow graph; it submits the job, streams the lifecycle back to you as a typed
`AsyncThrowingStream`, and the terminal event hands you the finished media. No callbacks, no delegates,
no Combine — just structured concurrency. It powers the **Comfy Go** iOS app.

## What it does

- **Submit** a workflow — `ComfyCloudClient.submit(_:)` with a `WorkflowRequest`
- **Stream** job events — `events(for:)` yields `.queued` → `.progress` → `.finalizing` → `.complete` / `.failed` / `.cancelled`
- **Receive** outputs — images arrive inline, videos stream to a temp file, both via `WorkflowOutput`
- **Reattach** after a network drop or app relaunch — `reattach(to:)` / `reattach(promptId:)`
- **Authenticate** — an API key, or "Sign in with Comfy" OAuth (authorization-code + PKCE)

## Requirements

| | |
|---|---|
| Swift | 5.9+ |
| Platforms | iOS 17+ · macOS 14+ |
| Dependencies | None (Foundation + CryptoKit only) |

## Install

Add the package in Xcode (**File → Add Package Dependencies…**) or in your `Package.swift`:

```swift
.package(url: "https://github.com/Comfy-Org/comfy-swift-sdk.git", from: "0.3.1")
```

…then list `ComfySwiftSDK` as a dependency of your target.

## Quick start

```swift
import ComfySwiftSDK

// 1. Construct a client. (API key shown here; OAuth is also supported — see below.)
let client = ComfyCloudClient(apiKey: "your-api-key")

// 2. Submit a ComfyUI API-format workflow graph. The SDK posts it verbatim.
let request = WorkflowRequest(workflowJSON: myWorkflowGraph)
let job = try await client.submit(request)

// 3. Stream the job's lifecycle until it reaches a terminal event.
for try await event in client.events(for: job) {
    switch event {
    case .queued:
        print("queued")
    case .progress(let fraction, let phase):
        print("\(phase): \(Int(fraction * 100))%")
    case .finalizing:
        print("downloading output…")
    case .complete(let output):
        for file in output.files {
            switch file {
            case .image(let data, let mimeType):
                print("image: \(data.count) bytes (\(mimeType))")
            case .video(let url):
                print("video: \(url.path)")
            }
        }
    case .failed(let error):
        print("failed: \(error)")
    case .cancelled:
        print("cancelled")
    }
}
```

Cancellation is cooperative: cancel the consuming `Task` and the SDK fires a best-effort server-side
cancel, then yields a final `.cancelled` event.

## Authentication

Two modes, both behind the same `ComfyCloudClient`:

```swift
// API key
let client = ComfyCloudClient(apiKey: "your-api-key")

// "Sign in with Comfy" OAuth (authorization-code + PKCE, no client secret on device)
let client = ComfyCloudClient(credential: .oauth(tokenProvider: { await myKeychain.accessToken() }))
```

### Sign in with Comfy (OAuth)

`ComfyAuth.signIn` runs the whole authorization-code + PKCE handshake in one call — build → present →
verify `state` → exchange → persist → return a ready, self-refreshing client. The SDK owns everything
except presenting the browser, which you inject through a `ComfyWebAuthPresenter` so the SDK never
imports `AuthenticationServices`:

```swift
import AuthenticationServices
import UIKit

// A thin app-side adapter over ASWebAuthenticationSession. `@MainActor` because the protocol
// requirement is main-actor-isolated: ASWebAuthenticationSession.start() must run on the main thread.
@MainActor
final class WebAuthPresenter: NSObject, ComfyWebAuthPresenter, ASWebAuthenticationPresentationContextProviding {
    // Held for the session's whole lifetime: ASWebAuthenticationSession is not retained by the
    // system, so a local-only reference would be deallocated after `start()` returns, cancelling
    // the flow and hanging sign-in.
    private var session: ASWebAuthenticationSession?

    func authenticate(url: URL, callbackURLScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackURLScheme) { [weak self] url, error in
                self?.session = nil   // release the one-shot session once the callback fires
                if let url { continuation.resume(returning: url) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    continuation.resume(throwing: ComfyError.authCancelled)   // user dismissed the sheet
                } else {
                    continuation.resume(throwing: error ?? ComfyError.authCancelled)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            // start() returns false without ever calling the completion handler when the system
            // refuses to present (bad anchor, redirect mismatch, missing entitlements). Guard it so
            // sign-in fails fast instead of hanging on a continuation that never resumes.
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: ComfyError.authCancelled)
                return
            }
        }
    }

    // Present on the app's active window — a detached `ASPresentationAnchor()` has no window scene
    // and the auth sheet would fail to display.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

// One call: the returned client is signed in and refreshes itself; tokens are persisted in `store`.
let client = try await ComfyAuth.signIn(presenter: WebAuthPresenter(), store: myTokenStore)
```

`store` is your `ComfyTokenStore` (Keychain, an encrypted file, …). On a later launch,
`ComfyAuth.restoreClient(store:)` rebuilds the same refreshable client without re-prompting, and
`ComfyAuth.signOut(store:)` clears it. Prefer a non-default `OAuthClientConfig`? Pass it as the
`config:` argument and it is threaded through the exchange and every silent refresh.

Credentials are held privately and are never logged, returned, or interpolated into error messages. If
you need the lower-level primitives, `ComfyCloudClient.buildAuthorizationRequest(config:)` and
`exchangeAuthorizationCode(_:codeVerifier:config:)` remain available.

### Two tiers: bring-your-own vs. batteries-included (`ComfyAuthKit`)

The example above is the **bring-your-own** tier: depend on `ComfySwiftSDK` alone and inject your own
`ComfyWebAuthPresenter` and `ComfyTokenStore`. The core SDK imports **Foundation only** — no
`AuthenticationServices`, no `Security` — so it stays reusable across surfaces and never forces a
UI/keychain dependency on a consumer that doesn't want one.

If you'd rather not hand-write that boilerplate, add the **`ComfyAuthKit`** product. It ships the two
obvious defaults — an `ASWebAuthenticationSession`-backed presenter and a Keychain-backed token store —
in a separate target that is *allowed* to import `AuthenticationServices` and `Security`:

```swift
import ComfySwiftSDK
import ComfyAuthKit

// Default presenter (ASWebAuthenticationSession) + default store (Keychain). No boilerplate.
let presenter = await ASWebAuthPresenter()          // @MainActor
let store = try KeychainTokenStore()                // stored under your bundle id + ".oauth"

let client = try await ComfyAuth.signIn(presenter: presenter, store: store)

// Later launch: rebuild the signed-in client from the Keychain without re-prompting.
let restored = try await ComfyAuth.restoreClient(store: store)
```

`ASWebAuthPresenter` retains the session until the callback fires and maps a user dismissal onto
`ComfyError.authCancelled`; it takes an optional `anchor:` when the automatic key-window choice isn't
right. `KeychainTokenStore` persists the three OAuth slots under
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (readable by background reattach while the device is
locked, kept out of backups and off other devices). The default `init()` derives its namespace from
the app's bundle id and throws `KeychainError.missingBundleIdentifier` in a process without one (e.g. a
CLI) rather than sharing a hard-coded namespace; pass an explicit `init(service:)` there and for test
isolation. Reach for `ComfyAuthKit` when you want defaults; depend on `ComfySwiftSDK` alone when you
want full control.

## Status

**Pre-1.0.** The SDK is battle-tested by the Comfy Go iOS app, builds clean, and ships with a full test
suite. The public API may still shift before a tagged 1.0 — pin to an exact version or commit if
you need stability today. Feedback on the surface is what we're looking for at this stage.

## Related projects

Clients for the same Comfy API v2 contract:

| Project | Language | Package |
|---|---|---|
| [comfy-python-sdk](https://github.com/Comfy-Org/comfy-python-sdk) | Python | `comfy-sdk` |
| [comfy-typescript-sdk](https://github.com/Comfy-Org/comfy-typescript-sdk) | TypeScript | `@comfyorg/sdk` |
| [comfy-swift-sdk](https://github.com/Comfy-Org/comfy-swift-sdk) | Swift | SwiftPM |

[comfy-api-proxy](https://github.com/Comfy-Org/comfy-api-proxy) fronts a
self-hosted ComfyUI with this same v2 contract.

## Contributing

Contributions are very welcome — issues, bug reports, and PRs all help. If you're building something on
Comfy Cloud in Swift and hit a rough edge, [open an issue](https://github.com/Comfy-Org/comfy-swift-sdk/issues);
real-world usage is the best guide for where this SDK should go next.

A few pointers:

- `swift build` and `swift test` should both pass before you open a PR.
- Keep the public surface small and `async`/`await`-native — no callbacks, delegates, or Combine.
- New error conditions go through the `ComfyError` taxonomy rather than leaking transport details.
- The SDK import boundary (sources import only `Foundation`, `CryptoKit`, and `os` — never `SwiftUI`, `SwiftData`, `Photos`, or `Security`) is enforced in-repo by `ImportBoundaryTests` under `swift test`.

For anything substantial, open an issue first so we can talk through the approach.

## License

Apache License 2.0 — see [LICENSE](LICENSE). Copyright © Comfy Org.
