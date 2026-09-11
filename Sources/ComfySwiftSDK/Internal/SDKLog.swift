import os
import Foundation

internal typealias SDKLogSink = @Sendable (_ category: String, _ message: String) -> Void

internal enum SDKLog {

    private static let transportLogger = Logger(
        subsystem: "org.comfy.ComfySwiftSDK",
        category: "transport"
    )
    private static let websocketLogger = Logger(
        subsystem: "org.comfy.ComfySwiftSDK",
        category: "websocket"
    )
    private static let pollingLogger = Logger(
        subsystem: "org.comfy.ComfySwiftSDK",
        category: "polling"
    )
    private static let routerLogger = Logger(
        subsystem: "org.comfy.ComfySwiftSDK",
        category: "router"
    )

    nonisolated(unsafe) internal static var _testSink: SDKLogSink?

    internal static func overrideSink(_ sink: @escaping SDKLogSink) {
        _testSink = sink
    }

    internal static func resetSink() {
        _testSink = nil
    }

    private static func emit(
        category: String,
        logger: Logger,
        _ message: @escaping @autoclosure () -> String
    ) {
        let msg = message()
        if let sink = _testSink {
            sink(category, msg)
            return
        }
        logger.error("\(msg, privacy: .public)")
    }

    internal static func transportPOSIXTranslated(code: Int32) {
        emit(
            category: "transport",
            logger: transportLogger,
            "translate: POSIX socket-drop posix=\(code)"
        )
    }

    internal static func transportUnknownFallback(errorType: String) {
        emit(
            category: "transport",
            logger: transportLogger,
            "translate: unknown error type=\(errorType)"
        )
    }

    internal static func wsOutputBuildFailed(error: ComfyError, jobId: String) {
        emit(
            category: "websocket",
            logger: websocketLogger,
            "ws.output-build failed: \(comfyErrorCaseName(error)) job=\(jobId)"
        )
    }

    internal static func wsReadLoopError(
        error: ComfyError,
        jobId: String,
        handingOffToPolling: Bool
    ) {
        let decision = handingOffToPolling ? "→polling-handoff" : "→failed"
        emit(
            category: "websocket",
            logger: websocketLogger,
            "ws.read-loop error: \(comfyErrorCaseName(error)) job=\(jobId) decision=\(decision)"
        )
    }

    internal static func wsExecutionError(jobId: String) {
        emit(
            category: "websocket",
            logger: websocketLogger,
            "ws.execution-error frame received job=\(jobId)"
        )
    }

    internal static func pollingOutputAssemblyFailed(error: ComfyError, jobId: String) {
        emit(
            category: "polling",
            logger: pollingLogger,
            "polling.output-assembly failed: \(comfyErrorCaseName(error)) job=\(jobId)"
        )
    }

    internal static func pollingGaveUp(error: ComfyError, jobId: String) {
        emit(
            category: "polling",
            logger: pollingLogger,
            "polling.gave-up: \(comfyErrorCaseName(error)) job=\(jobId)"
        )
    }

    internal static func pollingEmptyOutputExhausted(jobId: String) {
        emit(
            category: "polling",
            logger: pollingLogger,
            "polling.empty-output-exhausted job=\(jobId)"
        )
    }

    // MARK: - Comfy Router
    //
    // Nothing below ever takes the `Idempotency-Key`, the request body, the response body or
    // a credential as a parameter, so none of them can reach a log line: the Router surface
    // logs only a status, a spec-declared error bucket, and a retry delay. The key in
    // particular is deliberately absent — it is the caller's billing-idempotence token, and a
    // shared workspace keyspace makes a logged key usable by anyone who can read the log.

    /// One collect-loop resend: a `409`/`429`/`504` the contract pairs with a `Retry-After`,
    /// about to be re-sent under the same key after `retryAfter` seconds.
    internal static func routerCollectRetry(
        status: Int,
        errorType: RouterErrorType,
        retryAfter: TimeInterval
    ) {
        emit(
            category: "router",
            logger: routerLogger,
            "router.run collect-retry status=\(status) type=\(loggableType(errorType)) "
                + "retryAfter=\(Int(retryAfter))s"
        )
    }

    /// A Router run that ended on a `RouterError` — the terminal refusals, and the collectable
    /// ones whose `Retry-After` did not fit inside the caller's remaining deadline.
    internal static func routerRunFailed(status: Int, errorType: RouterErrorType) {
        emit(
            category: "router",
            logger: routerLogger,
            "router.run failed status=\(status) type=\(loggableType(errorType))"
        )
    }

    /// The bucket name that is safe to put in a log line.
    ///
    /// Every known bucket is a closed set declared in the vendored spec, so its wire value is
    /// the SDK's own text. ``RouterErrorType/unknown(_:)`` is not: it carries whatever the
    /// response's `X-Comfy-Error-Type` header — or the body's `error_type` — said, verbatim and
    /// unbounded, and both call sites above emit at `privacy: .public`. Folding it to a fixed
    /// string keeps response-controlled text out of the log while leaving the raw value on
    /// ``RouterError/errorType`` for callers that want to report it.
    private static func loggableType(_ errorType: RouterErrorType) -> String {
        if case .unknown = errorType { return "unknown" }
        return errorType.rawValue
    }

    /// A run refused before any request went out — a malformed model ID, an `Idempotency-Key`
    /// the contract cannot carry, a `timeout` that bounds nothing, or a base URL this SDK will
    /// not post a credential to. `reason` is one of the SDK's own stable identifiers, never
    /// caller text and never the rejected value.
    internal static func routerRejectedBeforeSend(reason: String) {
        emit(
            category: "router",
            logger: routerLogger,
            "router.run rejected before send: \(reason)"
        )
    }

    private static func comfyErrorCaseName(_ error: ComfyError) -> String {
        switch error {
        case .authInvalid:        return "ComfyError.authInvalid"
        case .authExpired:        return "ComfyError.authExpired"
        case .authStateMismatch:  return "ComfyError.authStateMismatch"
        case .authCancelled:      return "ComfyError.authCancelled"
        case .network:            return "ComfyError.network"
        case .offline:            return "ComfyError.offline"
        case .timeout:            return "ComfyError.timeout"
        case .serverRejected:     return "ComfyError.serverRejected"
        case .contentFiltered:    return "ComfyError.contentFiltered"
        case .jobFailed:          return "ComfyError.jobFailed"
        case .rateLimited:        return "ComfyError.rateLimited"
        case .cancelled:          return "ComfyError.cancelled"
        case .router:             return "ComfyError.router"
        case .unknown:            return "ComfyError.unknown"
        }
    }
}
