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
- **Run a Comfy Router model** — `client.models.run("bfl/flux-2-pro", input: [...])`, one synchronous call, idempotency-keyed
- **Queue a Comfy Router model** — `client.models.submit` / `subscribe` / `handle`, poll-authoritative queued delivery with an event stream

## Requirements

| | |
|---|---|
| Swift | 5.9+ |
| Platforms | iOS 17+ · macOS 14+ |
| Dependencies | None (Foundation + CryptoKit only) |

## Install

Add the package in Xcode (**File → Add Package Dependencies…**) or in your `Package.swift`:

```swift
.package(url: "https://github.com/Comfy-Org/comfy-swift-sdk.git", from: "0.6.0")
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

## Comfy Router — `client.models.run`

A second, separate surface on the same client: [Comfy Router](https://api.comfy.org) runs a **partner model by its canonical `{provider}/{model}` ID** over one synchronous request. There is no graph, no queue, and no event stream — the request body is the model's own native JSON input, the response is its own native JSON output, and Comfy re-envelopes neither.

```swift
import Foundation
import ComfySwiftSDK

let client = ComfyCloudClient(apiKey: ProcessInfo.processInfo.environment["COMFY_API_KEY"]!)
let result = try await client.models.run(
    "bfl/flux-2-pro",
    input: [
        "prompt": "a cat",
        "width": 1024,
    ]
)
print("Image URL:", result.output["images"][0]["url"].stringValue ?? "")
```

`result.output` is a read-only view for reading a field without declaring a type; `result.data` is the same document byte-for-byte, and `result.decode(MyOutput.self)` runs it through a `JSONDecoder` when you have a `Decodable` of your own. Both subscripts return `null` on a miss, so a deep read never traps.

**Alternate providers.** Three optional parameters route a run through a provider other than the model's default, and each is sent as a query parameter only when you pass it, so a call that names none posts to exactly the URL it always has. `modelProvider:` names the alternate provider to serve the model (`"fal"`, say). `strictMode:` controls how the body and the response are shaped once an alternate provider is selected: `false` (the server default) has Router translate between the model's native contract and the provider's real schema in both directions, while `true` sends and returns the provider's own raw shape unchanged, so your `input` must already be that provider's schema. `strictMode:` is only meaningful alongside `modelProvider:` and is not sent without it. `fallbackProvider:` is on by default and stands on its own — pass the exact literal `"false"` to opt out, so a failure is refused rather than retried against the model's other registered provider (`"False"`, `"0"` and `"no"` are *not* the opt-out and leave fallback on). All three apply to the synchronous run route, and because they travel as query parameters they are part of the request's identity under its `Idempotency-Key`: a re-send that collects an earlier run has to reproduce them along with `input`.

**Credentials.** Either mode works — an API key or OAuth. The Router surface shares the client's credential, its `URLSession`, and its OAuth refresh with the workflow surface; only the host differs. Pass `routerBaseURL:` to `ComfyCloudClient(credential:config:routerBaseURL:)` to point model runs at a staging host without moving the workflow surface off `cloud.comfy.org`.

**One key per call, and what a replay means.** Every run is sent under an `Idempotency-Key` — a fresh lowercase UUID unless you pass `idempotencyKey:`. The guarantee is a *billing* one: **a key is charged at most once.** Re-running under the same key is answered from that key's 24-hour record (`result.replayed == true`, not billed again) or, while the original generation is still in flight, collects that generation rather than starting a second one. Keys are scoped to the **workspace** your credential carries rather than to you, so a key you supply must be unique across that whole workspace — a colleague reusing the same string is answered from your record, or refused `409` if their request differs.

The SDK re-sends under the same key by itself for the two answers the contract says a re-send collects, each only when the response carried a `Retry-After` and what is left of your `timeout` covers both that wait and a short budget for the re-send to answer in: a `409 concurrency_limit_exceeded` and a `504 deadline_exceeded`. When the wait would fit but leave too little behind it, the `RouterError` already in hand is thrown instead — it names the request id and the key, so you know the generation is still collectable, which a bare client-side timeout would not tell you. Those are the only two responses the contract declares `Retry-After` on — a `429` carries none, so it is terminal in practice, and the SDK honours one only if some intermediary adds it. It never re-sends after a transport failure or a client-side timeout — that outcome is unknown, and re-sending blind is your call to make, not the SDK's.

**The 660-second default.** `RouterModels.defaultTimeout` is 660 s, deliberately a minute *above* Router's own 10-minute server deadline. A shorter client bound would give up first, turning the `504 deadline_exceeded` the server was about to send — which the collect loop handles — into a client-side timeout whose outcome nobody knows. The value is set on the request, not the session: `URLSession`'s 60-second idle default would otherwise cut a silent hold long before the model answered. It is spent from once, as a deadline — a re-send after a collect wait or a credential refresh inherits what is left of the budget rather than restarting it — and that deadline is measured on a **monotonic clock**, so an NTP correction mid-run neither extends your bound nor aborts a healthy generation. `timeout` must be between 1 second and 24 hours; a sub-second budget is refused outright rather than spent on one request too short to answer in.

**On iOS, persist the key before you await.** The SDK's session is a foreground default session, and iOS does not keep one alive across app suspension — a run that was in flight when the app suspended is not resumed for you. Pass your own `idempotencyKey:` so you hold it up front, persist it, and on relaunch call `run(..., idempotencyKey:)` again with that same key to collect the replay. Wrapping the call in `beginBackgroundTask(expirationHandler:)` buys the OS grace period for short runs; it is not a substitute for persisting the key.

Re-running with the same `input` produces byte-identical request bytes across app launches — the SDK serialises with sorted keys precisely so that a relaunch collects the replay instead of tripping the `409 invalid_input` that a re-used key with a *differing* request earns.

**Errors.** Router failures arrive as `ComfyError.router(RouterError)` with a spec-declared `errorType` to branch on — `.invalidInput`, `.insufficientCredits`, `.modelNotFound`, `.notEnabled`, `.deadlineExceeded` and the rest — plus `detail`, `validationErrors` for a `422`, `requestId` to quote in a support request, and the `idempotencyKey` the call ran under. A malformed model ID throws `ComfyError.serverRejected(reason: .other("invalid_model_id"))` *before* any request goes out. The catalog's IDs are exactly two segments: the `{provider}/{model}/{variant}` form that appears in the contract's prose is not addressable on this route, and is refused with its own identifier, `"invalid_model_id_variant_unsupported"`.

## Comfy Router — queued delivery (`submit` / `subscribe` / `handle`)

`run` holds one connection open until the model answers. **Queued delivery** is the other mode: Router accepts the request, hands back a `request_id`, and you poll for it. The whole point is that the request outlives the connection — a dropped network, a backgrounded app, a relaunch. Same three methods, same semantics, as the [Python](https://github.com/Comfy-Org/comfy-python-sdk) and [TypeScript](https://github.com/Comfy-Org/comfy-typescript-sdk) SDKs.

There is **no client-side flag**. The gate is server-side: outside the preview, Router answers `403 not_enabled` and the SDK throws `ComfyError.router` with `errorType == .notEnabled`.

### `subscribe` — submit, wait, collect, in one call

```swift
let result = try await client.models.subscribe(
    "bfl/flux-2-pro",
    input: ["prompt": "a cat"],
    onQueueUpdate: { update in
        print(update.state.rawValue, update.queuePosition ?? 0)
    }
)
print("Image URL:", result.output["images"][0]["url"].stringValue ?? "")
```

It returns the same `RouterRunResult` that `run` does. `timeout:` bounds the **whole** wait — the submit, the poll requests, their re-sends, the pauses between them and the result fetch — as a real wall-clock stop on a monotonic clock, not an idle timeout. It defaults to `RouterModels.defaultTimeout` (660 s).

### `submit` — get a handle back immediately

```swift
let handle = try await client.models.submit("bfl/flux-2-pro", input: ["prompt": "a cat"])
myDatabase.save(model: handle.model, requestId: handle.requestId)   // ← do this first

for try await update in handle.events() {
    switch update.state {
    case .inQueue:          print("position:", update.queuePosition ?? 0)
    case .inProgress:       print("running")
    case .completed:        print("done:", update.errorType?.rawValue ?? "ok")
    case .unknown(let raw): print("state:", raw)   // not terminal — polling continues
    }
}
let result = try await handle.result()
```

| | |
|---|---|
| `handle.status(timeout:)` | one authoritative poll, as a `RouterRequestStatus` (`state`, `queuePosition`, `errorType`, `retryAfter`) |
| `handle.result(timeout:)` | poll to completion, then return the provider's own payload — the same `RouterRunResult` `run` returns |
| `handle.cancel(timeout:)` | ask the server to cancel, as a **`PUT`** — the contract's own spelling |
| `handle.events(timeout:)` | the poll loop with its observations exposed — an `AsyncThrowingStream` yielding the first observation, every change of state or queue position, and the completion |

`status()` and `cancel()` are single calls bounded by `RouterModels.defaultRequestTimeout` (60 s). `result()` and `events()` poll, so their `timeout:` defaults to `RouterModels.defaultTimeout` (660 s) — and because the first poll is always made, `timeout: 0` on either reads "look once". On `result()` that bound covers the polling; the result download itself is floored at 60 s (see *How the polling behaves*). Neither cancels when its bound runs out: the queue is the server's, and a local clock running out says nothing about it. Only `subscribe`, which submitted the request, cleans up after itself.

### `handle` — rebuild after a relaunch

```swift
// New process, new client, hours later. No request is made here.
let handle = try client.models.handle(saved.model, requestId: saved.requestId)
let status = try await handle.status()
```

Both ids are validated locally, so a bad row in your database throws before anything reaches the wire rather than composing a request out of it. **On the queue route the recoverable thing is the `request_id`, not the `Idempotency-Key`** — it is server-assigned and outlives the connection by construction. Persist it the moment `submit` returns.

### How the polling behaves

Polling is **poll-authoritative**: the status route decides when a request is done. The pause between polls starts at half a second and backs off adaptively to at most ten; a server `Retry-After` beats that schedule outright and is capped at 60 seconds (`RouterRequestHandle.maximumRetryAfter`) before it is slept on. Consecutive identical observations are collapsed, so a queue that has not moved does not produce a stream of duplicates.

**A lost poll is retried, not fatal.** The status route is an unkeyed, idempotent `GET` that dispatches nothing and charges nothing, so a poll that could not be answered — a dropped connection, a radio that was off, a `5xx` — is swallowed and retried on the next tick rather than ending the watch. The retries draw on the same `timeout`; none of them lengthens it. A `401`/`403` and a `4xx` — a `404 request_not_found` above all — end the watch at once, because asking again would only repeat them. When the budget runs out with a poll failure outstanding, **that failure is what is thrown** rather than a bare `ComfyError.timeout`, so a watch that spent ten minutes against a `503` says so.

**The result fetch is floored at 60 seconds and can overrun your `timeout`.** That leg downloads the provider's payload rather than waiting on it, and a request that completed on the last poll has already been billed — so bounding the download at whatever fraction of a second the polling left over would report a timeout for a generation you are paying for. A `timeout:` above 60 seconds bounds it as stated.

The SDK composes every queue URL from the contract's own route templates. It does **not** follow the `status_url` / `response_url` / `cancel_url` the submit response carries: each of those calls stamps your credential onto the request, and a URL read out of a response body is a place the server could send it.

### Terminal is not the same as successful

Every terminal outcome reads `COMPLETED` on the status route — a provider failure, a content refusal, and a cancellation that took effect alike. What tells them apart is `error_type`. So:

- `subscribe` and `handle.result()` **throw** it, as `ComfyError.router(RouterError)` with the matching `errorType`. These are the calls that *collect*, so a `200` from the result route is never handed back as success when the completion reported a failure.
- `handle.status()` and `handle.events()` **report** it: `errorType` carries the bucket on the observation. These are *views of the queue's progress* — reading a status is how you discover a failure, so failing the read would leave nowhere to discover it from. Same split as the Python and TypeScript SDKs. `events()` can still throw for things that are not the request's own outcome: a transport failure, an elapsed `timeout`, a cancelled task.

Cancellation is a request, not a guarantee. `handle.cancel()` returns `.cancellationRequested` (`202`) or `.alreadyCompleted` (`400`) and throws for neither; the authority on what actually happened is the next `status()`.

### Giving up cancels, best-effort

When `subscribe`'s `timeout` elapses, or you cancel the calling `Task`, the SDK issues **one** cancel for the queued request — sent once, no retries, bounded to a few seconds — and then throws `ComfyError.timeout` or `ComfyError.cancelled`. The cancel is cleanup: its own failure never replaces the error you are being handed, and the request may still complete and be charged.

A budget that ran out while the *polls themselves* were failing is the one case that does not cancel: it throws the poll failure rather than `ComfyError.timeout`, and asking the server to abandon a generation that is probably fine, over a link that is evidently down, is not cleanup worth doing. Call `handle.cancel()` yourself if you want it.

### Idempotency on the queue route

`submit` accepts a `200`, `201` or `202` as an acceptance — what actually proves one is the `request_id` in the body, and a `2xx` without one throws rather than handing back a handle that addresses nothing. Each `submit` call mints one fresh lowercase-UUID `Idempotency-Key` and every re-send *inside that call* reuses it, so a `409 concurrency_limit_exceeded` collects the enqueue already in flight rather than queueing a second run. Pass `idempotencyKey:` to supply your own. A result collected through a handle that `client.models.handle(_:requestId:)` rebuilt reports `result.idempotencyKey == nil` — that handle never made a submit, so there is no key it could report.

The Router contract is vendored at [`spec/router-openapi.yaml`](spec/router-openapi.yaml) and pinned by `Scripts/contract/check_router_contract.py`, separately from the ComfyUI contract the workflow surface uses.

## Status

**Pre-1.0.** The SDK is battle-tested by the Comfy Go iOS app, builds clean, and ships with a full test
suite. The public API may still shift before a tagged 1.0 — pin to an exact version or commit if
you need stability today. Feedback on the surface is what we're looking for at this stage.

## Related projects

This SDK targets the ComfyUI front-facing API as served by Comfy Cloud — see
[`Scripts/contract/sdk-endpoints.yml`](Scripts/contract/sdk-endpoints.yml) for
the exact endpoints it depends on. The **Comfy API v2** clients are separate
projects and speak a different contract (`/api/v2/*`):

| Project | Language | Package |
|---|---|---|
| [comfy-python-sdk](https://github.com/Comfy-Org/comfy-python-sdk) | Python | `comfy-sdk` |
| [comfy-typescript-sdk](https://github.com/Comfy-Org/comfy-typescript-sdk) | TypeScript | `@comfyorg/sdk` |

[comfy-api-proxy](https://github.com/Comfy-Org/comfy-api-proxy) serves that v2
contract in front of a self-hosted ComfyUI.

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
