import Foundation

internal actor PollingFallback {

    static let activePollInterval: Duration = .milliseconds(1000)

    static let backoffLadder: [Duration] = [
        .milliseconds(2000),
        .milliseconds(4000),
        .milliseconds(8000)
    ]

    private let transport: Transport
    private let jobId: String
    private let startTime: Date
    private let clock: any Clock<Duration>

    internal init(
        transport: Transport,
        jobId: String,
        startTime: Date = Date(),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.transport = transport
        self.jobId = jobId
        self.startTime = startTime
        self.clock = clock
    }

    nonisolated internal func eventStream(
        lastEmittedPhase: String? = nil,
        lastEmittedFraction: Double = 0.0,
        hasEmittedQueued: Bool = false,
        hasEmittedFinalizing: Bool = false
    ) -> AsyncThrowingStream<JobEvent, Error> {
        let transport = self.transport
        let jobId = self.jobId
        let startTime = self.startTime
        let clock = self.clock
        return AsyncThrowingStream { continuation in
            let task = Task {
                await Self.runPollLoop(
                    transport: transport,
                    jobId: jobId,
                    startTime: startTime,
                    clock: clock,
                    initialLastPhase: lastEmittedPhase,
                    initialLastFraction: lastEmittedFraction,
                    initialQueuedEmitted: hasEmittedQueued,
                    initialFinalizingEmitted: hasEmittedFinalizing,
                    continuation: continuation
                )
            }
            continuation.onTermination = { @Sendable reason in
                task.cancel()
                Self.fireCancelJobIfCancelled(reason, transport: transport, jobId: jobId)
            }
        }
    }

    private static func runPollLoop(
        transport: Transport,
        jobId: String,
        startTime: Date,
        clock: any Clock<Duration>,
        initialLastPhase: String?,
        initialLastFraction: Double,
        initialQueuedEmitted: Bool,
        initialFinalizingEmitted: Bool,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async {
        var lastPhase: String? = initialLastPhase
        var lastFraction: Double = initialLastFraction
        var didEmitQueued: Bool = initialQueuedEmitted
        var didEmitFinalizing: Bool = initialFinalizingEmitted
        var backoffIndex: Int = 0
        var successWithoutOutputsRetries: Int = 0
        let successWithoutOutputsMaxRetries: Int = 8

        while !Task.isCancelled {
            let dto: JobDetailResponse
            do {
                dto = try await transport.fetchJobStatus(id: jobId)
                backoffIndex = 0
            } catch let error as ComfyError {
                if isTransient(error) {
                    let delay = backoffDelay(for: backoffIndex)
                    backoffIndex = min(backoffIndex + 1, backoffLadder.count - 1)
                    do {
                        try await clock.sleep(for: delay)
                    } catch {
                        continuation.yield(.cancelled)
                        continuation.finish()
                        return
                    }
                    continue
                } else {
                    SDKLog.pollingGaveUp(error: error, jobId: jobId)
                    continuation.yield(.failed(error))
                    continuation.finish()
                    return
                }
            } catch {
                let wrapped = ComfyError.unknown(underlying: error)
                SDKLog.pollingGaveUp(error: wrapped, jobId: jobId)
                continuation.yield(.failed(wrapped))
                continuation.finish()
                return
            }

            switch dto.status {
            case .pending:
                if !didEmitQueued {
                    continuation.yield(.queued)
                    didEmitQueued = true
                    lastPhase = "queued"
                }

            case .inProgress:
                successWithoutOutputsRetries = 0
                if !didEmitQueued {
                    continuation.yield(.queued)
                    didEmitQueued = true
                }
                let phase = derivePhase(from: dto)
                let fraction = deriveFraction(from: dto)
                if phase != lastPhase || fraction != lastFraction {
                    continuation.yield(.progress(fraction: fraction, phase: phase))
                    lastPhase = phase
                    lastFraction = fraction
                }

            case .completed:
                if !didEmitFinalizing {
                    continuation.yield(.finalizing)
                    didEmitFinalizing = true
                }
                if !hasOutputRefs(in: dto) {
                    if successWithoutOutputsRetries < successWithoutOutputsMaxRetries {
                        successWithoutOutputsRetries += 1
                        do {
                            try await clock.sleep(for: activePollInterval)
                        } catch {
                            continuation.yield(.cancelled)
                            continuation.finish()
                            return
                        }
                        continue
                    }
                    SDKLog.pollingEmptyOutputExhausted(jobId: jobId)
                    continuation.yield(.failed(.unknown(underlying: EmptyOutputError())))
                    continuation.finish()
                    return
                }
                do {
                    let output = try await buildOutput(
                        from: dto,
                        transport: transport,
                        startTime: startTime,
                        jobId: jobId
                    )
                    continuation.yield(.complete(output))
                    continuation.finish()
                    return
                } catch let error as ComfyError {
                    SDKLog.pollingOutputAssemblyFailed(error: error, jobId: jobId)
                    continuation.yield(.failed(error))
                    continuation.finish()
                    return
                } catch {
                    let wrapped = ComfyError.unknown(underlying: error)
                    SDKLog.pollingOutputAssemblyFailed(error: wrapped, jobId: jobId)
                    continuation.yield(.failed(wrapped))
                    continuation.finish()
                    return
                }

            case .failed:
                continuation.yield(.failed(Self.failureError(from: dto)))
                continuation.finish()
                return

            case .cancelled:
                continuation.yield(.cancelled)
                continuation.finish()
                return

            case .unknown:
                break
            }

            do {
                try await clock.sleep(for: activePollInterval)
            } catch {
                continuation.yield(.cancelled)
                continuation.finish()
                return
            }
        }

        continuation.yield(.cancelled)
        continuation.finish()
    }

    /// Fires a best-effort server-side cancel when a job event stream is torn
    /// down by consumer cancellation. Shared by the WebSocket and polling stream
    /// producers' `onTermination` closures, which both honor the documented
    /// "cancelling the consumer cancels the job" guarantee. `ReattachCoordinator`
    /// intentionally does not call this — reattaching to an already-running job
    /// must not cancel it.
    static func fireCancelJobIfCancelled(
        _ reason: AsyncThrowingStream<JobEvent, Error>.Continuation.Termination,
        transport: Transport,
        jobId: String
    ) {
        if case .cancelled = reason {
            Task.detached {
                await transport.cancelJob(id: jobId)
            }
        }
    }

    static func isTransient(_ error: ComfyError) -> Bool {
        switch error {
        case .network, .offline, .timeout:
            return true
        case .rateLimited:
            return true
        case .authInvalid, .authExpired, .authStateMismatch, .authCancelled,
             .contentFiltered, .serverRejected, .jobFailed, .cancelled, .unknown:
            return false
        }
    }

    static func backoffDelay(for index: Int) -> Duration {
        let clamped = min(max(index, 0), backoffLadder.count - 1)
        return backoffLadder[clamped]
    }

    /// Classify a terminal `failed` job.
    ///
    /// The job detail carries `execution_error.exception_message`, which is where
    /// a partner node reports things like "Payment Required: Please add credits to
    /// your account to use this node". That message used to be dropped on the
    /// floor — every execution failure became a bare `.jobFailed(phase:)`, so the
    /// consumer could only say "nothing came back" no matter what actually went
    /// wrong. Recognised billing failures are promoted to a typed rejection;
    /// everything else keeps the existing `.jobFailed(phase:)` shape.
    static func failureError(from dto: JobDetailResponse) -> ComfyError {
        let message = (dto.executionError?.exceptionMessage ?? "").lowercased()
        if !message.isEmpty {
            if message.contains("payment required")
                || message.contains("add credits")
                || message.contains("insufficient credit")
                || message.contains("out of credit")
                || message.contains("no credits") {
                return .serverRejected(reason: .insufficientCredits)
            }
        }
        return .jobFailed(phase: derivePhase(from: dto))
    }

    static func derivePhase(from dto: JobDetailResponse) -> String {
        switch dto.status {
        case .pending:
            return "queued"
        case .completed:
            return "saving"
        case .failed:
            if let nodeType = dto.executionError?.nodeType, !nodeType.isEmpty {
                return PhaseLabel.forNode(nodeType)
            }
            return "executing"
        case .inProgress, .cancelled, .unknown:
            return "executing"
        }
    }

    /// The jobs REST endpoint carries no numeric progress signal — `JobDetailResponse`
    /// exposes only `status`/`outputs`/`executionError`/timestamps, with no field to
    /// derive a completion fraction from. A real fraction is available *only* on the
    /// live WebSocket `progress` frame (`value / max`, see `WebSocketSession`); the
    /// polling and reattach paths that call this run precisely when that frame is
    /// unavailable. So `0.0` is the intentional, honest value here — a placeholder that
    /// keeps the phase half of change-detection working while reporting "fraction
    /// unknown," not a stub awaiting derivation. `runPollLoop` still surfaces phase
    /// transitions, but the `fraction != lastFraction` half of its change guard is dead
    /// from this source by design; `ReattachCoordinator` emits a single `0.0` progress.
    static func deriveFraction(from dto: JobDetailResponse) -> Double {
        return 0.0
    }

    static func hasOutputRefs(in dto: JobDetailResponse) -> Bool {
        guard let outputs = dto.outputs else { return false }
        for (_, payload) in outputs {
            if let images = payload.images, !images.isEmpty { return true }
            if let gifs = payload.gifs, !gifs.isEmpty { return true }
            if let videos = payload.videos, !videos.isEmpty { return true }
        }
        return false
    }

    static func buildOutput(
        from dto: JobDetailResponse,
        transport: Transport,
        startTime: Date,
        jobId: String
    ) async throws -> WorkflowOutput {
        var imageRefs: [OutputFileRef] = []
        var videoRefs: [OutputFileRef] = []
        for (_, payload) in dto.outputs ?? [:] {
            if let images = payload.images {
                imageRefs.append(contentsOf: images)
            }
            if let gifs = payload.gifs {
                videoRefs.append(contentsOf: gifs)
            }
            if let videos = payload.videos {
                videoRefs.append(contentsOf: videos)
            }
        }

        if imageRefs.isEmpty && videoRefs.isEmpty {
            throw ComfyError.unknown(underlying: EmptyOutputError())
        }

        return try await assembleOutput(
            imageRefs: imageRefs,
            videoRefs: videoRefs,
            transport: transport,
            startTime: startTime,
            jobId: jobId
        )
    }

    /// Downloads the collected output references and assembles the final
    /// `WorkflowOutput`. Shared by the WebSocket success path and the polling
    /// fallback — the two callers collect the refs differently (incremental
    /// `executed`-frame buffering vs. `dto.outputs` extraction) and handle the
    /// empty-refs case on their own, but the download-and-assemble tail is
    /// identical.
    static func assembleOutput(
        imageRefs: [OutputFileRef],
        videoRefs: [OutputFileRef],
        transport: Transport,
        startTime: Date,
        jobId: String
    ) async throws -> WorkflowOutput {
        var files: [WorkflowOutput.OutputFile] = []
        do {
            for ref in imageRefs {
                let (data, mime) = try await withTransientRetry {
                    try await transport.downloadView(
                        filename: ref.filename,
                        subfolder: ref.subfolder,
                        type: ref.type
                    )
                }
                files.append(.image(data, mimeType: mime))
            }
            for ref in videoRefs {
                let ext = (ref.filename as NSString).pathExtension
                let url = try await withTransientRetry {
                    try await transport.downloadViewToTempFile(
                        filename: ref.filename,
                        subfolder: ref.subfolder,
                        type: ref.type,
                        suggestedExtension: ext.isEmpty ? "mp4" : ext
                    )
                }
                files.append(.video(url: url))
            }
        } catch {
            // A later download failing leaves the temp files from earlier video
            // refs orphaned in the caches directory — the caller discards this
            // partial result, so nothing else will ever clean them up. Delete any
            // temp files already materialized before rethrowing.
            for case let .video(url) in files {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }

        let duration = Date().timeIntervalSince(startTime)
        return WorkflowOutput(
            files: files,
            durationSeconds: duration,
            jobId: jobId
        )
    }

    /// Delay schedule for the output-download retrier: a single 250 ms pause
    /// before the second attempt, and none before the third (`.zero`). Kept as
    /// data so the schedule stays visible and the attempt budget derives from
    /// it rather than being a second, drift-prone constant.
    static let outputFetchRetryDelays: [Duration] = [.milliseconds(250), .zero]

    static var outputFetchMaxAttempts: Int { outputFetchRetryDelays.count + 1 }

    /// Runs `body`, retrying transient `ComfyError`s on a fixed, injected delay
    /// schedule. `delays[i]` is awaited (via `sleep`) after the `(i + 1)`-th
    /// attempt fails transiently, before the next attempt; the total attempt
    /// budget is `delays.count + 1`. Non-transient errors propagate immediately,
    /// and the last transient error is rethrown once the budget is exhausted.
    ///
    /// The schedule and the sleep primitive are BOTH injected so each call site
    /// keeps its own timing unchanged: the output retrier sleeps on `Task`
    /// (real clock), the reattach retrier on its test-injectable `Clock`. A
    /// non-positive delay (e.g. `.zero`) pads the attempt budget without a
    /// pause — the next attempt runs immediately, exactly as a hand-rolled loop
    /// with no `sleep` on that step would.
    static func withTransientRetry<T>(
        delays: [Duration],
        sleep: (Duration) async throws -> Void,
        body: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 0 ... delays.count {
            do {
                return try await body()
            } catch let error as ComfyError where isTransient(error) {
                lastError = error
                if attempt < delays.count, delays[attempt] > .zero {
                    try await sleep(delays[attempt])
                }
                continue
            } catch {
                throw error
            }
        }
        throw lastError!
    }

    static func withTransientRetry<T>(
        body: () async throws -> T
    ) async throws -> T {
        try await withTransientRetry(
            delays: outputFetchRetryDelays,
            sleep: { duration in try await Task.sleep(for: duration) },
            body: body
        )
    }

    /// Builds a `PollingFallback` and drains its event stream into `continuation`,
    /// applying the shared terminal-event contract: yield every event, `finish()`
    /// once on the first `.complete` / `.failed` / `.cancelled`, `finish()` on
    /// natural stream end, and wrap any thrown error as `.failed(.unknown(...))`
    /// before finishing. Both the WebSocket-drop handoff and the reattach path
    /// forward here, so which `JobEvent` cases are terminal (and the finish-once
    /// discipline) lives in exactly one place instead of being duplicated.
    static func drain(
        into continuation: AsyncThrowingStream<JobEvent, Error>.Continuation,
        transport: Transport,
        jobId: String,
        startTime: Date,
        clock: any Clock<Duration>,
        lastEmittedPhase: String?,
        lastEmittedFraction: Double,
        hasEmittedQueued: Bool,
        hasEmittedFinalizing: Bool
    ) async {
        let polling = PollingFallback(
            transport: transport,
            jobId: jobId,
            startTime: startTime,
            clock: clock
        )
        do {
            for try await event in polling.eventStream(
                lastEmittedPhase: lastEmittedPhase,
                lastEmittedFraction: lastEmittedFraction,
                hasEmittedQueued: hasEmittedQueued,
                hasEmittedFinalizing: hasEmittedFinalizing
            ) {
                continuation.yield(event)
                switch event {
                case .complete, .failed, .cancelled:
                    continuation.finish()
                    return
                default:
                    continue
                }
            }
            continuation.finish()
        } catch {
            continuation.yield(.failed(.unknown(underlying: error)))
            continuation.finish()
        }
    }
}
