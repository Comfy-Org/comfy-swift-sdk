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
