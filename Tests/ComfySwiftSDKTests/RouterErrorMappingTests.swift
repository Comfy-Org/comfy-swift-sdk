//
//  RouterErrorMappingTests.swift
//  ComfySwiftSDKTests
//
//  The Swift-side half of the Comfy Router contract gate. Two things are under
//  test here:
//
//    1. `RouterErrorType`'s wire vocabulary — every value the vendored spec
//       (`spec/router-openapi.yaml`) declares round-trips, an undeclared value
//       degrades to `.unknown` instead of failing, and `known` is the spec's
//       fifteen values in the spec's declaration order.
//    2. `RouterErrorMapping.routerError(status:headers:body:idempotencyKey:)` —
//       the pure classification of one HTTP response into a `RouterError`:
//       header-over-body-over-status precedence, the `422` `detail[]` parse,
//       and the three header reads (`Retry-After`, `X-Comfy-Request-Id`,
//       `Idempotent-Replayed`).
//
//  `Scripts/contract/check_router_contract.py` asserts (1) against the spec
//  file itself. Both exist on purpose: the suite is where a contributor sees
//  the failure, and the script is the CI job that fails a spec-only PR which
//  never ran `swift test`.
//

import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("RouterError — wire vocabulary and response classification")
struct RouterErrorMappingTests {

    /// The spec's fifteen buckets in declaration order — the six request-tier
    /// values first, then the nine transport-tier ones. Written out literally
    /// rather than derived from `RouterErrorType.known` so this file is an
    /// independent statement of the contract; deriving it would make the order
    /// assertion below tautological.
    private static let specOrder: [String] = [
        "invalid_input",
        "content_policy_violation",
        "provider_error",
        "provider_timeout",
        "insufficient_credits",
        "model_not_found",
        "unauthorized",
        "forbidden",
        "concurrency_limit_exceeded",
        "client_disconnected",
        "internal_error",
        "deadline_exceeded",
        "not_enabled",
        "service_unavailable",
        "rate_limited"
    ]

    private static func makeError(
        status: Int,
        headers: [String: String] = [:],
        body: String = "",
        idempotencyKey: String? = "key-1"
    ) -> RouterError {
        RouterErrorMapping.routerError(
            status: status,
            headers: headers,
            body: Data(body.utf8),
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - RouterErrorType

    @Test func every_wire_value_round_trips() {
        for value in Self.specOrder {
            let bucket = RouterErrorType(rawValue: value)
            #expect(bucket.rawValue == value, "\(value) did not round-trip (got '\(bucket.rawValue)')")
            #expect(bucket != .unknown(value), "\(value) decoded as .unknown — it is a declared bucket")
        }
    }

    @Test func unknown_value_is_preserved_verbatim() {
        let bucket = RouterErrorType(rawValue: "x")
        #expect(bucket == .unknown("x"))
        #expect(bucket.rawValue == "x")
    }

    @Test func known_is_the_spec_set_in_spec_order() {
        #expect(RouterErrorType.known.count == 15)
        #expect(RouterErrorType.known.map(\.rawValue) == Self.specOrder)
    }

    /// The named cases and the wire table must not drift apart: every declared
    /// case has a row, so none silently falls through `rawValue`'s
    /// `internal_error` degradation.
    @Test func named_cases_all_have_a_wire_row() {
        let named: [RouterErrorType] = [
            .invalidInput, .contentPolicyViolation, .providerError, .providerTimeout,
            .insufficientCredits, .modelNotFound, .unauthorized, .forbidden,
            .concurrencyLimitExceeded, .clientDisconnected, .internalError,
            .deadlineExceeded, .notEnabled, .serviceUnavailable, .rateLimited
        ]
        #expect(named == RouterErrorType.known)
        for bucket in named {
            #expect(RouterErrorType(rawValue: bucket.rawValue) == bucket)
        }
    }

    // MARK: - errorType precedence

    @Test func header_wins_over_body() {
        let error = Self.makeError(
            status: 500,
            headers: ["X-Comfy-Error-Type": "content_policy_violation"],
            body: #"{"detail":"nope","error_type":"provider_error"}"#
        )
        #expect(error.errorType == .contentPolicyViolation)
        #expect(error.detail == "nope")
    }

    @Test func body_wins_over_status_when_header_is_absent() {
        let error = Self.makeError(
            status: 500,
            body: #"{"detail":"nope","error_type":"not_enabled"}"#
        )
        #expect(error.errorType == .notEnabled)
    }

    /// Header names arrive in whatever casing the transport chose; the lookup
    /// must not depend on it.
    @Test func header_lookup_is_case_insensitive() {
        let error = Self.makeError(
            status: 500,
            headers: [
                "x-comfy-error-type": "rate_limited",
                "RETRY-AFTER": "7",
                "x-comfy-request-id": "req-42",
                "IDEMPOTENT-REPLAYED": "true"
            ]
        )
        #expect(error.errorType == .rateLimited)
        #expect(error.retryAfter == 7)
        #expect(error.requestId == "req-42")
        #expect(error.replayed)
    }

    /// A blank header must not decode as `.unknown("")` — it is no signal at
    /// all, so classification falls through to the body and then the status.
    @Test func blank_header_falls_through_to_body() {
        let error = Self.makeError(
            status: 500,
            headers: ["X-Comfy-Error-Type": "   "],
            body: #"{"detail":"nope","error_type":"provider_error"}"#
        )
        #expect(error.errorType == .providerError)
    }

    @Test func unrecognised_header_value_becomes_unknown() {
        let error = Self.makeError(
            status: 500,
            headers: ["X-Comfy-Error-Type": "brand_new_bucket"]
        )
        #expect(error.errorType == .unknown("brand_new_bucket"))
    }

    // MARK: - Status fallback

    @Test func status_fallback_table() {
        let expected: [(Int, RouterErrorType)] = [
            (400, .invalidInput),
            (401, .unauthorized),
            (402, .insufficientCredits),
            (403, .forbidden),
            (404, .modelNotFound),
            (409, .invalidInput),
            (413, .internalError),
            (422, .invalidInput),
            (429, .concurrencyLimitExceeded),
            (500, .internalError),
            (503, .serviceUnavailable),
            (504, .providerTimeout),
            (418, .internalError),
            (0, .internalError)
        ]
        for (status, bucket) in expected {
            let error = Self.makeError(status: status)
            #expect(error.errorType == bucket, "status \(status) classified as \(error.errorType)")
            #expect(error.httpStatus == status)
        }
    }

    /// The two `409` buckets are acted on in opposite ways, so the fallback reads
    /// `Retry-After` rather than guessing the more common one. Only reachable when
    /// Router sent neither the header nor a body `error_type`, which is already
    /// off-contract — but guessing `invalid_input` there sends a caller to a NEW key
    /// and a second billable generation, so the guess is not free.
    @Test func conflict_status_is_settled_by_retry_after() {
        #expect(Self.makeError(status: 409).errorType == .invalidInput)
        #expect(
            Self.makeError(status: 409, headers: ["Retry-After": "5"]).errorType
                == .concurrencyLimitExceeded
        )
        // Present but unusable still counts: presence is the contract's signal, and this
        // is the reading whose remedy cannot dispatch a second generation.
        #expect(
            Self.makeError(status: 409, headers: ["retry-after": "not-a-number"]).errorType
                == .concurrencyLimitExceeded
        )
        // The header and the body still win over the status when Router sends them.
        #expect(
            Self.makeError(
                status: 409,
                headers: ["Retry-After": "5", "X-Comfy-Error-Type": "invalid_input"]
            ).errorType == .invalidInput
        )
    }

    /// The safe reading is only safe when there is a key to re-send. Without one,
    /// `concurrency_limit_exceeded` names a remedy the caller cannot perform, and repeating
    /// an unkeyed request is itself what dispatches a second billable generation. The
    /// contract calls the case off-wire anyway — `Retry-After` is documented absent on an
    /// unkeyed call — so a header here came from a proxy or a server bug.
    @Test func keyless_conflict_does_not_read_as_concurrency() {
        #expect(
            Self.makeError(
                status: 409,
                headers: ["Retry-After": "5"],
                idempotencyKey: nil
            ).errorType == .invalidInput
        )
        // A key present restores the concurrency reading.
        #expect(
            Self.makeError(
                status: 409,
                headers: ["Retry-After": "5"],
                idempotencyKey: "key-1"
            ).errorType == .concurrencyLimitExceeded
        )
        // An explicit `error_type` still wins over the status for a keyless call.
        #expect(
            Self.makeError(
                status: 409,
                headers: ["Retry-After": "5", "X-Comfy-Error-Type": "concurrency_limit_exceeded"],
                idempotencyKey: nil
            ).errorType == .concurrencyLimitExceeded
        )
        // A blank key is no key: the contract's `RouterIdempotencyKey` is `minLength: 1`,
        // and an empty string must not buy the concurrency reading that a real key does.
        #expect(
            Self.makeError(
                status: 409,
                headers: ["Retry-After": "5"],
                idempotencyKey: ""
            ).errorType == .invalidInput
        )
        // A blank `Retry-After:` is not a signal Router sent, matching every other string
        // read in the mapper.
        #expect(
            Self.makeError(status: 409, headers: ["Retry-After": "   "]).errorType
                == .invalidInput
        )
    }

    /// The delay means "wait, then re-send the SAME key". With no key there is nothing to
    /// re-send, and a retry layer acting on the number would repeat an UNKEYED request —
    /// a second billable dispatch. The contract documents the header absent on an unkeyed
    /// call, so surfacing one would invent advice Router did not give.
    @Test func retry_after_is_withheld_from_an_unkeyed_call() {
        #expect(
            Self.makeError(
                status: 504,
                headers: ["Retry-After": "5"],
                idempotencyKey: nil
            ).retryAfter == nil
        )
        #expect(
            Self.makeError(
                status: 504,
                headers: ["Retry-After": "5"],
                idempotencyKey: ""
            ).retryAfter == nil
        )
        // With a key it is surfaced as before, and a blank key normalises to "no key".
        #expect(
            Self.makeError(
                status: 504,
                headers: ["Retry-After": "5"],
                idempotencyKey: "key-1"
            ).retryAfter == 5
        )
        #expect(Self.makeError(status: 504, idempotencyKey: "").idempotencyKey == nil)
    }

    // MARK: - Body parsing

    @Test func validation_array_body_parses_into_details() {
        let body = """
        {"detail":[
          {"loc":["body","images",0],"msg":"Image is too small","type":"image_too_small",
           "ctx":{"min_width":512},"input":"https://example.invalid/a.png"},
          {"loc":["body","prompt"],"msg":"Field required","type":"missing"}
        ]}
        """
        let error = Self.makeError(status: 422, body: body)

        // No `X-Comfy-Error-Type` header and no body `error_type` (the 422 body
        // has no such field by contract), so the status is what classifies it.
        #expect(error.errorType == .invalidInput)
        #expect(error.validationErrors.count == 2)

        let first = error.validationErrors[0]
        #expect(first.loc == [.key("body"), .key("images"), .index(0)])
        #expect(first.location == "body.images.0")
        #expect(first.msg == "Image is too small")
        #expect(first.type == "image_too_small")
        #expect(first.ctx?["min_width"].intValue == 512)
        #expect(first.input?.stringValue == "https://example.invalid/a.png")

        let second = error.validationErrors[1]
        #expect(second.location == "body.prompt")
        #expect(second.ctx == nil)
        #expect(second.input == nil)

        #expect(error.detail == "body.images.0: Image is too small; body.prompt: Field required")
    }

    /// The header still classifies a `422` when Router sends one — the body
    /// carries no bucket of its own, which is why the header exists.
    @Test func validation_body_still_honours_the_header() {
        let error = Self.makeError(
            status: 422,
            headers: ["X-Comfy-Error-Type": "content_policy_violation"],
            body: #"{"detail":[{"loc":["body"],"msg":"m","type":"t"}]}"#
        )
        #expect(error.errorType == .contentPolicyViolation)
        #expect(error.validationErrors.count == 1)
    }

    @Test func string_detail_body_is_used_verbatim() {
        let error = Self.makeError(
            status: 404,
            body: #"{"detail":"No model 'bfl/nope'. Did you mean bfl/flux-2-pro?","error_type":"model_not_found"}"#
        )
        #expect(error.errorType == .modelNotFound)
        #expect(error.detail == "No model 'bfl/nope'. Did you mean bfl/flux-2-pro?")
        #expect(error.validationErrors.isEmpty)
    }

    @Test func absent_or_unusable_body_falls_back_to_http_status() {
        #expect(Self.makeError(status: 502).detail == "HTTP 502")
        #expect(Self.makeError(status: 502, body: "<html>gateway</html>").detail == "HTTP 502")
        #expect(Self.makeError(status: 502, body: "{}").detail == "HTTP 502")
        #expect(Self.makeError(status: 502, body: #"{"detail":[]}"#).detail == "HTTP 502")
        // A `detail` of an unexpected scalar type is neither a string nor an array.
        #expect(Self.makeError(status: 502, body: #"{"detail":7}"#).detail == "HTTP 502")
        // Entries that parse but carry nothing: the summary would be `": "`, which says
        // less than the status does.
        #expect(
            Self.makeError(status: 422, body: #"{"detail":[{"loc":[],"msg":"","type":""}]}"#)
                .detail == "HTTP 422"
        )
    }

    /// Building an error must never throw or drop the whole diagnosis because
    /// one field of one entry was mistyped.
    @Test func mistyped_validation_entries_degrade_rather_than_fail() {
        let body = """
        {"detail":[
          "not an object",
          {"loc":["body",{"nested":true},2],"msg":123},
          {"loc":"not an array","msg":"m","type":"t"}
        ]}
        """
        let error = Self.makeError(status: 422, body: body)
        #expect(error.validationErrors.count == 2)   // the bare string entry is skipped
        // The unusable `loc` segment is dropped; the usable ones survive in order.
        #expect(error.validationErrors[0].loc == [.key("body"), .index(2)])
        #expect(error.validationErrors[0].msg == "")
        #expect(error.validationErrors[0].type == "")
        #expect(error.validationErrors[1].loc.isEmpty)
        #expect(error.validationErrors[1].location == "")
    }

    // MARK: - Header reads

    @Test func retry_after_accepts_delta_seconds_only() {
        func retryAfter(_ raw: String) -> TimeInterval? {
            Self.makeError(status: 429, headers: ["Retry-After": raw]).retryAfter
        }
        #expect(retryAfter("2") == 2)
        // The contract declares `minimum: 1`; a `0` is advice to retry with no delay at
        // all, so it reads as no advice.
        #expect(retryAfter("0") == nil)
        #expect(retryAfter(" 30 ") == 30)
        #expect(retryAfter("-1") == nil)
        // The ceiling is the 24 hours an `Idempotency-Key` lives: past it the record is
        // gone before the caller wakes, so re-sending the key would dispatch and bill a
        // SECOND generation instead of collecting the first. Advice that cannot be followed
        // is dropped rather than clamped — clamping to the ceiling lands the caller exactly
        // on the expiry boundary, and `nil` is safe because re-sending the same key early
        // is idempotent.
        #expect(retryAfter("86400") == 86400)
        #expect(retryAfter("86401") == nil)
        #expect(retryAfter("172800") == nil)
        // Past the ceiling and too wide for `Int` are the same fact and get the same
        // answer; reading them apart would be an artefact of `Int`'s width.
        #expect(retryAfter("9223372036854775807") == nil)
        #expect(retryAfter("9223372036854775808") == nil)
        // Too wide for `Int` at all: `Int.init(_: String)` answers nil, never traps.
        #expect(retryAfter("99999999999999999999999") == nil)
        #expect(retryAfter("Wed, 21 Oct 2026 07:28:00 GMT") == nil)
        #expect(retryAfter("2.5") == nil)
        #expect(retryAfter("") == nil)
        #expect(Self.makeError(status: 429).retryAfter == nil)
    }

    @Test func request_id_is_trimmed_and_capped() {
        #expect(Self.makeError(status: 500, headers: ["X-Comfy-Request-Id": "  abc  "]).requestId == "abc")
        #expect(Self.makeError(status: 500, headers: ["X-Comfy-Request-Id": "   "]).requestId == nil)
        #expect(Self.makeError(status: 500).requestId == nil)

        let long = String(repeating: "a", count: 300)
        let capped = Self.makeError(status: 500, headers: ["X-Comfy-Request-Id": long]).requestId
        #expect(capped?.count == 128)
    }

    /// `Idempotent-Replayed` is sent only when true, so the SDK branches on its
    /// presence — not on its value.
    @Test func replayed_is_header_presence() {
        #expect(Self.makeError(status: 400, headers: ["Idempotent-Replayed": "true"]).replayed)
        #expect(Self.makeError(status: 400, headers: ["Idempotent-Replayed": ""]).replayed)
        #expect(!Self.makeError(status: 400).replayed)
    }

    @Test func idempotency_key_is_carried_through() {
        #expect(Self.makeError(status: 500, idempotencyKey: "k-9").idempotencyKey == "k-9")
        // A call that carried no key — every catalog read, and an unkeyed run — records
        // `nil`, which says "nothing to re-send". An empty string could not say that
        // without being mistaken for a key.
        #expect(Self.makeError(status: 500, idempotencyKey: nil).idempotencyKey == nil)
    }

    // MARK: - Route constants

    /// The two constants the drift check pins to the spec. Asserted here too so
    /// a change to them fails `swift test`, not only the Python job.
    @Test func route_constants_match_the_vendored_spec() {
        #expect(RouterConstants.runPathTemplate == "/v2/models/{provider}/{model}")
        #expect(RouterConstants.defaultBaseURL.absoluteString == "https://api.comfy.org")
    }

    // MARK: - RouterJSON

    @Test func router_json_wraps_json_serialization_output() throws {
        let data = Data(#"{"a":1,"b":true,"c":[null,"s",2.5],"d":{"e":false}}"#.utf8)
        let json = RouterJSON(any: try JSONSerialization.jsonObject(with: data))

        #expect(json["a"].intValue == 1)
        #expect(json["a"].doubleValue == 1)
        // The classic bridging trap: an integral NSNumber must not decode as a Bool.
        #expect(json["a"].boolValue == nil)
        #expect(json["b"].boolValue == true)
        #expect(json["b"].doubleValue == nil)
        #expect(json["c"][0] == .null)
        #expect(json["c"][1].stringValue == "s")
        #expect(json["c"][2].doubleValue == 2.5)
        #expect(json["c"][2].intValue == nil)          // 2.5 is not an exact integer
        #expect(json["c"].arrayValue?.count == 3)
        #expect(json["d"]["e"].boolValue == false)
        #expect(json["d"].objectValue?.keys.sorted() == ["e"])
    }

    /// An out-of-`Int`-range JSON integer must read as `nil`, not trap.
    ///
    /// Regression: `Double(Int.max)` rounds *up* to 2^63, so an inclusive upper
    /// bound admitted `9223372036854775808` and then crashed in `Int(_:)` — from
    /// server-controlled bytes, inside the error builder that must never fail.
    /// `loc` is the reachable path: a `loc` segment is read with `intValue`.
    @Test func router_json_int_value_rejects_out_of_range_integers() throws {
        let data = Data(#"{"hi":9223372036854775808,"lo":-1e30,"ok":9223372036854775807}"#.utf8)
        let json = RouterJSON(any: try JSONSerialization.jsonObject(with: data))
        #expect(json["hi"].intValue == nil)
        #expect(json["lo"].intValue == nil)
        #expect(json["ok"].intValue == Int.max)  // integral and in range: exact
        // `JSONSerialization` rounds -9223372036854775809 onto exactly -2^63 before this
        // type sees it, so an inclusive lower bound would answer `Int.min` — off by one and
        // indistinguishable from an exact read. Both bounds are exclusive on the `.number`
        // path, so it reads `nil` instead: no answer rather than a wrong one.
        let boundary = RouterJSON(any: try JSONSerialization.jsonObject(
            with: Data(#"{"lo":-9223372036854775809}"#.utf8)))
        #expect(boundary["lo"].intValue == nil)
        // An integer-written `Int.min` is unaffected: it arrives as `.int` and never
        // reaches the `.number` range test.
        let exactMin = RouterJSON(any: try JSONSerialization.jsonObject(
            with: Data(#"{"lo":-9223372036854775808}"#.utf8)))
        #expect(exactMin["lo"] == .int(Int.min))
        #expect(exactMin["lo"].intValue == Int.min)

        // The same value arriving where the mapper actually calls `intValue`.
        let error = Self.makeError(
            status: 422,
            body: #"{"detail":[{"loc":["body",9223372036854775808,1],"msg":"m","type":"t"}]}"#
        )
        #expect(error.validationErrors.count == 1)
        #expect(error.validationErrors[0].loc == [.key("body"), .index(1)])
    }

    /// A 64-bit integer must survive verbatim. Rounding one through `Double` is silent:
    /// a generation seed that comes back off by one produces unreproducible output from
    /// a call that looked like it succeeded, which is exactly what `ctx`/`input` being
    /// "carried verbatim" promises will not happen.
    @Test func router_json_carries_64_bit_integers_exactly() throws {
        let data = Data(#"{"seed":9007199254740993,"max":9223372036854775807,"neg":-9007199254740993,"whole":2.0,"frac":2.5}"#.utf8)
        let json = RouterJSON(any: try JSONSerialization.jsonObject(with: data))

        #expect(json["seed"] == .int(9_007_199_254_740_993))
        #expect(json["seed"].intValue == 9_007_199_254_740_993)
        #expect(json["max"].intValue == Int.max)
        #expect(json["neg"].intValue == -9_007_199_254_740_993)
        // Written as a float, so it stays one: the number's declared type decides, not
        // its value. It still reads back as an `Int`, because it is exactly integral.
        #expect(json["whole"] == .number(2))
        #expect(json["whole"].intValue == 2)
        #expect(json["frac"] == .number(2.5))
        #expect(json["frac"].intValue == nil)
        // Both numeric cases answer `doubleValue`, and neither is equal to the other —
        // distinct wire shapes, deliberately distinct values.
        #expect(json["seed"].doubleValue == 9_007_199_254_740_992)   // Double's limit
        #expect(RouterJSON.int(1) != RouterJSON.number(1))
        // An integral literal past `Int64.max` arrives as an *unsigned* NSNumber whose
        // `int64Value` wraps to `Int.min`; it must not be read as an `Int` at all.
        let wide = RouterJSON(any: try JSONSerialization.jsonObject(
            with: Data(#"{"hi":9223372036854775808}"#.utf8)))
        #expect(wide["hi"].intValue == nil)
        #expect(wide["hi"].doubleValue != nil)
    }

    /// An explicit JSON `null` for `ctx`/`input` reads as `nil` — the contract's
    /// way of saying "no bound" is to omit the field, and a caller should not
    /// have to distinguish the two spellings.
    @Test func explicit_null_ctx_and_input_read_as_nil() {
        let error = Self.makeError(
            status: 422,
            body: #"{"detail":[{"loc":["body"],"msg":"m","type":"t","ctx":null,"input":null}]}"#
        )
        #expect(error.validationErrors.count == 1)
        #expect(error.validationErrors[0].ctx == nil)
        #expect(error.validationErrors[0].input == nil)
    }

    /// Every miss returns `.null` rather than trapping, so a deep read on an
    /// unexpected shape is safe.
    @Test func router_json_misses_return_null() {
        let json = RouterJSON(any: ["a": [1]] as [String: Any])
        #expect(json["nope"] == .null)
        #expect(json["a"][9] == .null)
        #expect(json["a"]["nope"] == .null)          // subscripting an array by key
        #expect(json["a"][0]["nope"][3] == .null)    // chained through a scalar
    }
}
