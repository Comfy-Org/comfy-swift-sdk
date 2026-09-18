//
//  RouterModelsE2ETests.swift
//  ComfySwiftSDKTests
//
//  Live end-to-end test of the Router model-run surface (`client.models.run`) against a
//  deployment, exercising the alt-provider controls (`modelProvider`, `strictMode`,
//  `fallbackProvider`) added on this branch.
//
//  Skipped unless pointed at a live Router deployment:
//
//      export COMFY_ROUTER_BASE_URL="https://stagingapi.comfy.org"
//      export COMFY_API_KEY="comfyui-..."
//      swift test --no-parallel --filter "Router Models E2E"
//
//  Gated on COMFY_ROUTER_BASE_URL being set explicitly (not just COMFY_API_KEY): these calls
//  dispatch real partner generations and cost credits, so they run only against a deployment
//  the caller deliberately named via `routerBaseURL:`, never accidentally against the default
//  prod host (`https://api.comfy.org`). The provider under test defaults to `fal` and the model
//  ids to fal's registered alt-provider legs; override with COMFY_ROUTER_E2E_PROVIDER /
//  _IMAGE_MODEL / _VIDEO_MODEL to point elsewhere.
//
//  The provider gate must be enabled for the caller on the target deployment, or these are
//  refused `ComfyError.router` with `RouterErrorType.notEnabled` (that refusal is itself the
//  signal the gate is off, not an SDK fault).
//

import Testing
import Foundation
import ComfySwiftSDK

@Suite(
    "Router Models E2E (live)",
    .enabled(
        if: !(ProcessInfo.processInfo.environment["COMFY_ROUTER_BASE_URL"] ?? "").isEmpty
            && !(ProcessInfo.processInfo.environment["COMFY_API_KEY"] ?? "").isEmpty,
        "set COMFY_ROUTER_BASE_URL and COMFY_API_KEY to run the Router model e2e tests"
    )
)
struct RouterModelsE2ETests {

    // MARK: - Environment

    /// The API key the runs authenticate with, or `nil` when unset.
    static var apiKey: String? {
        let value = ProcessInfo.processInfo.environment["COMFY_API_KEY"] ?? ""
        return value.isEmpty ? nil : value
    }

    /// The Router deployment the runs are addressed to, or `nil` when unset or unparseable.
    /// This is the gate: absent, the whole suite is skipped, so a run never lands on prod by
    /// default.
    static var routerBaseURL: URL? {
        let value = ProcessInfo.processInfo.environment["COMFY_ROUTER_BASE_URL"] ?? ""
        return value.isEmpty ? nil : URL(string: value)
    }

    static var provider: String {
        ProcessInfo.processInfo.environment["COMFY_ROUTER_E2E_PROVIDER"] ?? "fal"
    }

    /// A native model id that carries an alt-provider leg — the `{provider}/{model}` the run
    /// route is addressed by, not the alt-provider's own catalog id.
    static var imageModel: String {
        ProcessInfo.processInfo.environment["COMFY_ROUTER_E2E_IMAGE_MODEL"] ?? "openai/gpt-image-2"
    }

    static var videoModel: String {
        ProcessInfo.processInfo.environment["COMFY_ROUTER_E2E_VIDEO_MODEL"]
            ?? "byteplus/dreamina-seedance-2-0-260128"
    }

    /// A direct image generation, held open server-side.
    static let imageTimeout: TimeInterval = 300
    /// A submit-and-poll video, polled server-side inside the single call.
    static let videoTimeout: TimeInterval = 600

    // MARK: - Helpers

    /// A client whose Router surface points at the named deployment. `#require` keeps the
    /// failure legible if the suite gate is ever bypassed with a malformed URL.
    private func makeClient() throws -> ComfyCloudClient {
        let key = try #require(Self.apiKey, "COMFY_API_KEY must be set")
        let base = try #require(
            Self.routerBaseURL,
            "COMFY_ROUTER_BASE_URL must be set to a valid URL"
        )
        return ComfyCloudClient(credential: .apiKey(key), routerBaseURL: base)
    }

    /// The image URL (or inline data-URI) from a native OpenAI-image response, or `nil`.
    private func imageURL(_ result: RouterRunResult) -> String? {
        let first = result.output["data"][0]
        return first["url"].stringValue ?? first["b64_json"].stringValue
    }

    // MARK: - Tests

    @Test("modelProvider=<name>, strictMode default: native input in, native out")
    func altProviderTranslatesNativeRoundTrip() async throws {
        // The caller sends the model's OWN native contract and gets the model's own native
        // output back, with the alt-provider translation invisible — the whole point of the
        // default (strictMode=false) path.
        let result = try await makeClient().models.run(
            Self.imageModel,
            input: ["prompt": "a red fox in a snowy forest", "n": 1, "size": "1024x1024"],
            modelProvider: Self.provider,
            timeout: Self.imageTimeout
        )
        #expect(
            imageURL(result) != nil,
            "no image in native round-trip response: \(result.output)"
        )
    }

    @Test("strictMode=true: the provider's own raw shape, passed through both ways")
    func strictModeReturnsTheProvidersRawShape() async throws {
        // The body is the provider's OWN schema, and the response is its raw shape — no native
        // translation.
        let result = try await makeClient().models.run(
            Self.imageModel,
            input: ["prompt": "a red fox, oil painting",
                    "image_size": ["width": 1024, "height": 1024]],
            modelProvider: Self.provider,
            strictMode: true,
            timeout: Self.imageTimeout
        )
        #expect(result.output.objectValue?.isEmpty == false, "empty strict-mode response")
        // The provider's own shape, not the native `data[]` envelope.
        #expect(
            result.output["data"] == .null || result.output["images"] != .null,
            "strictMode response looks native, expected the provider's raw shape: \(result.output)"
        )
    }

    @Test("fallbackProvider=false is accepted and the run still succeeds")
    func fallbackProviderOptOutIsAccepted() async throws {
        // Opting out only changes behavior on a primary failure, so on success it is a no-op.
        let result = try await makeClient().models.run(
            Self.imageModel,
            input: ["prompt": "a red fox, watercolor", "n": 1, "size": "1024x1024"],
            modelProvider: Self.provider,
            fallbackProvider: "false",
            timeout: Self.imageTimeout
        )
        #expect(imageURL(result) != nil, "no image with fallbackProvider=false: \(result.output)")
    }

    @Test("a submit-and-poll (video) model served via the alt provider")
    func submitPollModelViaAltProvider() async throws {
        // run() blocks while the server polls to completion, and the native terminal shape comes
        // back. This is the second dispatch mode — the image models above are direct.
        let result = try await makeClient().models.run(
            Self.videoModel,
            input: [
                "content": [["type": "text",
                             "text": "a red fox running through a snowy forest"]],
                "resolution": "480p",
                "ratio": "16:9",
                "duration": 5,
            ],
            modelProvider: Self.provider,
            timeout: Self.videoTimeout
        )
        #expect(result.output.objectValue?.isEmpty == false, "empty video response")
        #expect(
            result.output["status"].stringValue == "succeeded",
            "video not succeeded: \(result.output["status"])"
        )
        #expect(
            result.output["content"]["video_url"].stringValue?.isEmpty == false,
            "no video_url in terminal response: \(result.output)"
        )
    }
}
