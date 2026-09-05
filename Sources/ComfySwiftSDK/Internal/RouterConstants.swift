import Foundation

/// The two Comfy Router route constants the SDK hard-codes.
///
/// Both are declared by the vendored contract — `spec/router-openapi.yaml` — and
/// `Scripts/contract/check_router_contract.py` fails CI when either drifts from it: the
/// path template against the unique path whose `post.operationId` is `runRouterModel`, and
/// the base URL against `servers[0].url`. A sync that *moves* the route while these
/// constants stay put would otherwise leave the SDK posting to a route the contract no
/// longer declares, with nothing in CI noticing.
///
/// Keep each value a single string literal on one line: the checker extracts them by regex.
enum RouterConstants {

    /// The model-run route, with its two path parameters unsubstituted.
    static let runPathTemplate = "/v2/models/{provider}/{model}"

    /// The default Router host. Force-unwrapped because the literal is a compile-time
    /// constant the drift check pins to the spec — if it ever fails to parse, that is a
    /// build-breaking edit to this line, not a runtime condition.
    static let defaultBaseURL = URL(string: "https://api.comfy.org")!
}
