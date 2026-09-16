import Testing
import Foundation
@testable import ComfySwiftSDK

/// `ComfyError` declared only `Error, Sendable`, so `String(describing:)` and every `"\(error)"`
/// fell to Swift's enum reflection — which prints associated values verbatim and unbounded, with
/// control characters passed straight through. These cover the sanitizing renderer that replaced
/// it, and mirror the `RouterError` description tests in `RouterErrorMappingTests`.
@Suite("ComfyError — log-safe description")
struct ComfyErrorDescriptionTests {

    /// The failing URL a `URLSession` error carries in its bridged `userInfo`, query string and
    /// all. Reflection emitted the whole `Error Domain=… UserInfo={…}` string.
    private static let leakyURL =
        "https://api.comfy.example/api/prompt?token=SENTINEL-QUERY-SECRET&workflow=private-name"

    private static func urlErrorWithFailingURL(_ url: String = leakyURL) -> URLError {
        URLError(
            .badServerResponse,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey: url,
                NSLocalizedDescriptionKey: "bad response\nfrom \(url)",
            ]
        )
    }

    // MARK: - (a) a boxed URLError's failing URL is bounded and control-stripped

    @Test func a_boxed_url_error_does_not_emit_its_failing_url_unbounded() {
        // The leak that motivated this: `URLError`'s `NSError` bridging puts the failing URL —
        // query string included — into `userInfo`, and reflection printed all of it.
        let padded = Self.leakyURL + String(repeating: "&pad=x", count: 4_000)

        for error in [
            ComfyError.network(underlying: Self.urlErrorWithFailingURL(padded)),
            ComfyError.unknown(underlying: Self.urlErrorWithFailingURL(padded)),
        ] {
            let rendered = "\(error)"

            #expect(!rendered.contains("\n"), "a boxed error forged a log line")
            #expect(!rendered.contains("\r"))
            // Unbounded is the defect: the whole query string must not survive.
            #expect(!rendered.contains(padded), "the failing URL was emitted in full")
            #expect(rendered.utf8.count < 700, "rendered \(rendered.utf8.count) bytes")
            // Still debuggable: the concrete type survives, which is what says what failed.
            #expect(rendered.contains("URLError"))
            #expect(rendered.hasPrefix("ComfyError."))
        }
    }

    @Test func a_boxed_url_session_error_does_not_leak_the_websocket_token() {
        // The SDK's own WebSocket URL carries the API key / OAuth access token as a `token` query
        // item (`WebSocketSession.buildWebSocketURL`), and a `receive()` failure on that task
        // reaches `.network` / `.unknown` through `Transport.translate` carrying the failing URL
        // in its bridged `userInfo`. A LENGTH bound alone does not save this: the whole leaking
        // reflection measures ~271 bytes against a 512-byte budget, so the credential survives it
        // intact. The `userInfo` is therefore not rendered at all.
        let credential = "SENTINEL-OAUTH-ACCESS-TOKEN"
        let ws = "wss://api.comfy.example/ws?clientId=A1B2&token=\(credential)"
        let boxed = URLError(
            .secureConnectionFailed,
            userInfo: [
                NSURLErrorFailingURLErrorKey: URL(string: ws)!,
                NSURLErrorFailingURLStringErrorKey: ws,
            ]
        )
        // Sanity: the leak is real and fits the budget, so this test is not vacuous.
        #expect(String(describing: boxed).contains(credential))
        #expect(String(describing: boxed).utf8.count < LogSafeText.defaultByteBudget)

        for error in [ComfyError.network(underlying: boxed), ComfyError.unknown(underlying: boxed)] {
            let rendered = "\(error)"
            #expect(!rendered.contains(credential), "the credential reached the rendering: \(rendered)")
            #expect(!rendered.contains("token="))
            #expect(!rendered.contains("clientId"))
            // Still diagnostic: the domain, the code and the endpoint survive.
            #expect(rendered.contains("NSURLErrorDomain"))
            #expect(rendered.contains("\(URLError.Code.secureConnectionFailed.rawValue)"))
            #expect(rendered.contains("wss://api.comfy.example/ws"))
        }
    }

    @Test func a_url_session_error_without_a_failing_url_still_renders_its_code() {
        let rendered = "\(ComfyError.network(underlying: URLError(.badServerResponse)))"

        #expect(rendered.contains("NSURLErrorDomain"))
        #expect(rendered.contains("\(URLError.Code.badServerResponse.rawValue)"))
        #expect(rendered.contains("URLError"))
    }

    @Test func a_non_url_error_still_reflects_normally() {
        // The redaction is scoped to `NSURLErrorDomain`; everything else keeps the reflected text
        // that makes a log line worth reading, bounded and control-stripped.
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        let rendered = "\(ComfyError.network(underlying: posix))"

        #expect(rendered.contains(NSPOSIXErrorDomain))
        #expect(rendered.contains("\(Int(ECONNRESET))"))
    }

    @Test func a_boxed_error_reflecting_newlines_cannot_forge_a_log_line() {
        // `SubmitErrorBody` has no `description` of its own before this change, so the raw server
        // string printed verbatim — newlines and all.
        let body = SubmitErrorBody(message: "ok\nERROR: transfer approved\r\nFATAL: nope")
        let rendered = "\(ComfyError.unknown(underlying: body))"

        #expect(!rendered.contains("\n"))
        #expect(!rendered.contains("\r"))
        // Neutralised rather than dropped — the text is still readable.
        #expect(rendered.contains("transfer approved"))
    }

    @Test func submit_error_body_is_bounded_when_reflected_on_its_own() {
        // Belt and braces: the value is thrown boxed, but an `Error` can be reflected anywhere —
        // a consumer unwrapping `underlying`, a crash reporter, `os_log`.
        let body = SubmitErrorBody(message: "a\u{2028}b" + String(repeating: "z", count: 10_000))
        let rendered = "\(body)"

        #expect(!rendered.contains("\u{2028}"))
        #expect(rendered.utf8.count < 600, "rendered \(rendered.utf8.count) bytes")
        #expect(rendered.hasSuffix("…)"))
    }

    @Test func job_execution_error_is_bounded_when_reflected_on_its_own() {
        // Same shape as `SubmitErrorBody`: all three fields come straight off the server's
        // `execution_error` websocket frame and are boxed as `.unknown(underlying:)`.
        let execError = JobExecutionError(
            exceptionType: "ValueError\nFATAL: forged",
            exceptionMessage: String(repeating: "m", count: 10_000),
            nodeType: "KSampler\u{2028}two"
        )

        for rendered in ["\(execError)", "\(ComfyError.unknown(underlying: execError))"] {
            #expect(!rendered.contains("\n"))
            #expect(!rendered.contains("\u{2028}"))
            #expect(!rendered.contains(String(repeating: "m", count: 10_000)))
            #expect(rendered.contains("ValueError"))
        }

        // A field that was absent says so rather than rendering blank.
        #expect("\(JobExecutionError(exceptionType: nil, exceptionMessage: nil, nodeType: nil))"
            == "JobExecutionError(type: nil, message: nil, node: nil)")
    }

    // MARK: - (b) serverRejected(.other(_:)) is stripped and capped

    @Test func a_server_rejection_reason_is_control_stripped_and_capped() {
        let hostile = "a\nb" + String(repeating: "q", count: 4_000)
        let rendered = "\(ComfyError.serverRejected(reason: .other(hostile)))"

        #expect(!rendered.contains("\n"))
        #expect(rendered.contains("a.b"), "the newline should be replaced, not dropped")
        #expect(rendered.utf8.count < 600, "rendered \(rendered.utf8.count) bytes")
        #expect(!rendered.contains(hostile))
    }

    @Test func the_closed_rejection_reasons_render_by_name() {
        let expected: [(ServerRejectionReason, String)] = [
            (.malformedWorkflow, "malformedWorkflow"),
            (.modelUnavailable, "modelUnavailable"),
            (.quotaExceeded, "quotaExceeded"),
            (.insufficientCredits, "insufficientCredits"),
        ]
        for (reason, label) in expected {
            #expect("\(ComfyError.serverRejected(reason: reason))"
                == "ComfyError.serverRejected(reason: \(label))")
        }
    }

    // MARK: - (c) .router delegates to RouterError's own renderer

    @Test func the_router_case_delegates_and_keeps_the_idempotency_key_out() {
        // `RouterError.description` deliberately withholds the `Idempotency-Key` — it is scoped to
        // the workspace, so anyone who can read the log can spend it. Re-rendering RouterError's
        // stored fields here instead of delegating would have leaked it straight back.
        let inner = RouterErrorMapping.routerError(
            status: 409,
            headers: ["X-Comfy-Error-Type": "concurrency_limit_exceeded", "X-Comfy-Request-Id": "req-9"],
            body: Data(#"{"detail":"busy"}"#.utf8),
            idempotencyKey: "super-secret-workspace-key"
        )
        let rendered = "\(ComfyError.router(inner))"

        #expect(rendered == "ComfyError.router(\(inner.description))")
        #expect(!rendered.contains("super-secret-workspace-key"))
        #expect(!String(reflecting: ComfyError.router(inner)).contains("super-secret-workspace-key"))
        // Still useful: the bucket and the support id survive the delegation.
        #expect(rendered.contains("concurrency_limit_exceeded"))
        #expect(rendered.contains("req-9"))
    }

    // MARK: - (d) the byte budget

    @Test func an_overlong_value_is_truncated_with_an_ellipsis_at_the_byte_budget() {
        let rendered = LogSafeText.bounded(String(repeating: "x", count: 10_000))

        #expect(rendered.utf8.count == LogSafeText.defaultByteBudget)
        #expect(rendered.hasSuffix("…"))
    }

    @Test func the_budget_is_utf8_bytes_and_not_characters() {
        // A scalar cap says nothing about how much a multi-byte value writes: 512 four-byte
        // scalars is 2 KiB past a 512-*character* cap.
        let rendered = LogSafeText.bounded(String(repeating: "𝄞", count: 1_000))

        #expect(rendered.utf8.count <= LogSafeText.defaultByteBudget)
        #expect(rendered.hasSuffix("…"))
        // The cut lands on a scalar boundary, so the value is still valid text.
        #expect(rendered.dropLast().allSatisfy { $0 == "𝄞" })
    }

    @Test func the_bound_holds_even_for_a_budget_too_small_for_the_marker() {
        // No caller passes one, but "the result never exceeds the budget" should not have an
        // unstated exception for the budget that cannot hold the `…` saying it was exceeded.
        for budget in 0...3 {
            #expect(LogSafeText.bounded("abcdef", to: budget).utf8.count <= budget)
        }
    }

    @Test func a_value_inside_the_budget_is_returned_whole_and_unmarked() {
        #expect(LogSafeText.bounded("plain") == "plain")
        #expect(LogSafeText.bounded("") == "")
        let exactly = String(repeating: "x", count: LogSafeText.defaultByteBudget)
        #expect(LogSafeText.bounded(exactly) == exactly)
    }

    @Test func sanitizing_shrinks_a_value_rather_than_pushing_it_over_the_budget() {
        // U+2028 is 3 UTF-8 bytes and sanitizes to a 1-byte `.`, so 400 of them fit the budget
        // after sanitizing even though the raw value is 1,200 bytes. Nothing was dropped, so
        // nothing should claim it was.
        let rendered = LogSafeText.bounded(String(repeating: "\u{2028}", count: 400))

        #expect(rendered == String(repeating: ".", count: 400))
        #expect(!rendered.hasSuffix("…"))
    }

    @Test func the_ellipsis_is_charged_to_the_budget_and_not_added_to_it() {
        // The path that bit: 600 U+2028 scalars sanitize to 600 single-byte dots, so the 512-scalar
        // prefix DID drop content while still fitting the byte budget. Appending `…` to a value
        // that already fills the budget rendered 515 bytes against a "512-byte" bound.
        for value in [String(repeating: "\u{2028}", count: 600), String(repeating: "x", count: 600)] {
            let rendered = LogSafeText.bounded(value)
            #expect(rendered.utf8.count == LogSafeText.defaultByteBudget,
                    "rendered \(rendered.utf8.count) bytes")
            #expect(rendered.hasSuffix("…"))
        }
    }

    @Test func separators_foundation_calls_newlines_are_replaced_too() {
        // U+2028/U+2029 are Zl/Zp, NOT in `CharacterSet.controlCharacters` — but a log viewer
        // renders them as line breaks, so they forge a line just as well.
        let rendered = "\(ComfyError.serverRejected(reason: .other("ok\u{2028}ERROR: forged\u{2029}two")))"

        #expect(!rendered.contains("\u{2028}"))
        #expect(!rendered.contains("\u{2029}"))
        #expect(rendered.contains("ERROR: forged"))
    }

    // MARK: - the payload-free and already-bounded cases

    @Test func every_payload_free_case_renders_a_short_stable_label() {
        let expected: [(ComfyError, String)] = [
            (.authInvalid, "ComfyError.authInvalid"),
            (.authExpired, "ComfyError.authExpired"),
            (.authStateMismatch, "ComfyError.authStateMismatch"),
            (.authCancelled, "ComfyError.authCancelled"),
            (.offline, "ComfyError.offline"),
            (.timeout, "ComfyError.timeout"),
            (.contentFiltered, "ComfyError.contentFiltered"),
            (.cancelled, "ComfyError.cancelled"),
        ]
        for (error, label) in expected {
            #expect("\(error)" == label)
            #expect(String(reflecting: error) == label, "debugDescription should mirror description")
        }
    }

    @Test func auth_code_rejected_renders_both_fields_and_their_absence() {
        #expect("\(ComfyError.authCodeRejected(code: "invalid_grant", detail: nil))"
            == "ComfyError.authCodeRejected(code: invalid_grant, detail: nil)")

        // Already scrubbed and clamped at construction; `loggable` is belt and braces, and this is
        // what proves the renderer does not depend on that.
        let rendered = "\(ComfyError.authCodeRejected(code: "a\nb", detail: "c\u{2029}d"))"
        #expect(!rendered.contains("\n"))
        #expect(rendered.contains("a.b"))
        #expect(rendered.contains("c.d"))
    }

    @Test func job_failed_renders_its_closed_vocabulary_phase() {
        #expect("\(ComfyError.jobFailed(phase: "execution"))"
            == "ComfyError.jobFailed(phase: execution)")
    }

    @Test func a_huge_retry_after_does_not_trap_the_description() {
        // `Int(retryAfter)` would be a TRAPPING conversion on a response-controlled value:
        // `Retry-After: 9223372036854775807` stores `TimeInterval(Int.max)`, which as a `Double`
        // is exactly 2^63 — one past `Int.max` — so `Int(_:)` is a precondition failure that
        // terminates the process at the exact call site this renderer exists to make safe.
        for seconds in [9_223_372_036_854_775_807, 9_223_372_036_854_775_806, 999_999_999_999_999_999] {
            let error = ComfyError.rateLimited(retryAfter: TimeInterval(seconds))
            #expect(!"\(error)".isEmpty)
            #expect(!String(reflecting: error).isEmpty)
        }
        #expect("\(ComfyError.rateLimited(retryAfter: nil))" == "ComfyError.rateLimited(retryAfter: nil)")
        #expect("\(ComfyError.rateLimited(retryAfter: 1.5))" == "ComfyError.rateLimited(retryAfter: 1.5s)")
    }

    @Test func the_case_labels_agree_with_the_ones_SDKLog_emits() {
        // `SDKLog.comfyErrorCaseName` is the vocabulary this renderer reuses. If the two drift, a
        // reader correlating a log line with a rendered error has to know both spellings.
        let cases: [ComfyError] = [
            .authInvalid, .authExpired, .authStateMismatch, .authCancelled,
            .authCodeRejected(code: nil, detail: nil),
            .network(underlying: URLError(.timedOut)),
            .offline, .timeout,
            .serverRejected(reason: .quotaExceeded),
            .contentFiltered,
            .jobFailed(phase: "execution"),
            .rateLimited(retryAfter: nil),
            .cancelled,
            .router(RouterErrorMapping.routerError(status: 500, headers: [:], body: Data(), idempotencyKey: nil)),
            .unknown(underlying: URLError(.badServerResponse)),
        ]
        for error in cases {
            #expect("\(error)".hasPrefix(SDKLog.comfyErrorCaseName(error)),
                    "'\(error)' does not lead with '\(SDKLog.comfyErrorCaseName(error))'")
        }
    }
}
