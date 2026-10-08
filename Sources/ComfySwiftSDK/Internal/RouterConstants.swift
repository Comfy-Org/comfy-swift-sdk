import Foundation

/// The Comfy Router route constants the SDK hard-codes.
///
/// Every one is declared by the vendored contract — `spec/router-openapi.yaml` — and
/// `Scripts/contract/check_router_contract.py` fails CI when one drifts from it: each path
/// template against the unique path carrying that route's `operationId`, and the base URL
/// against `servers[0].url`. A sync that *moves* a route while these constants stay put would
/// otherwise leave the SDK addressing a route the contract no longer declares, with nothing in
/// CI noticing.
///
/// Keep each value a single string literal on one line: the checker extracts them by regex.
enum RouterConstants {

    /// The synchronous model-run route (`runRouterModel`), with its two path parameters
    /// unsubstituted.
    static let runPathTemplate = "/v2/models/{provider}/{model}"

    /// The queued-delivery submit route (`submitRouterModelRequest`). `POST`.
    static let submitPathTemplate = "/v2/models/{provider}/{model}/requests"

    /// The queued-delivery status route (`getRouterModelRequestStatus`). `GET`.
    static let requestStatusPathTemplate = "/v2/models/{provider}/{model}/requests/{request_id}/status"

    /// The queued-delivery result route (`getRouterModelRequestResult`). `GET`.
    static let requestResultPathTemplate = "/v2/models/{provider}/{model}/requests/{request_id}"

    /// The queued-delivery cancel route (`cancelRouterModelRequest`).
    ///
    /// **`PUT`, not `POST`** — the contract's own spelling, and the one thing about this route
    /// that is easy to get wrong by analogy with every other write in this SDK.
    static let requestCancelPathTemplate = "/v2/models/{provider}/{model}/requests/{request_id}/cancel"

    /// The default Router host. Force-unwrapped because the literal is a compile-time
    /// constant the drift check pins to the spec — if it ever fails to parse, that is a
    /// build-breaking edit to this line, not a runtime condition.
    static let defaultBaseURL = URL(string: "https://api.comfy.org")!
}
