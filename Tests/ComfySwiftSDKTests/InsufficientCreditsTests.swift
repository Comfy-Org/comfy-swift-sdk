//
//  InsufficientCreditsTests.swift
//  ComfySwiftSDKTests
//
//  A billing failure must arrive as `.serverRejected(reason: .insufficientCredits)`,
//  not as a network error and not as a bare `.jobFailed`. Both were real: a 402
//  fell through `assertHTTPOK`'s `default` and surfaced as `.network`, so the app
//  told the user to check their connection; and a partner node refusing mid-run
//  had its `execution_error.exception_message` discarded, so the app could only
//  say "nothing came back".
//

import Foundation
import Testing
@testable import ComfySwiftSDK

@Suite("Insufficient credits classification")
struct InsufficientCreditsTests {

    // MARK: HTTP status

    @Test("402 is a credit rejection, not a network error")
    func paymentRequiredStatusIsTyped() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://cloud.comfy.org/api/prompt")!,
            statusCode: 402, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        do {
            try Transport.checkStatus(response)
            Issue.record("402 should throw")
        } catch let error as ComfyError {
            guard case .serverRejected(let reason) = error,
                  case .insufficientCredits = reason else {
                Issue.record("expected .insufficientCredits, got \(error)")
                return
            }
        }
    }

    // MARK: body message

    @Test("a payment message is classified from the body")
    func paymentMessageInBodyIsTyped() throws {
        let body = Data(#"{"error":{"message":"Payment Required: Please add credits to your account to use this node."}}"#.utf8)
        do {
            try Transport.checkBody(body, status: 402)
            Issue.record("expected a throw")
        } catch let error as ComfyError {
            guard case .serverRejected(let reason) = error,
                  case .insufficientCredits = reason else {
                Issue.record("expected .insufficientCredits, got \(error)")
                return
            }
        }
    }

    @Test("credit wording wins over the looser quota match")
    func creditsBeatQuota() throws {
        // Contains "billing", which the quota branch matches — the credit branch
        // runs first because the advice differs (top up vs wait for the reset).
        let body = Data(#"{"error":"Please add credits to your billing account"}"#.utf8)
        do {
            try Transport.checkBody(body, status: 400)
            Issue.record("expected a throw")
        } catch let error as ComfyError {
            guard case .serverRejected(let reason) = error,
                  case .insufficientCredits = reason else {
                Issue.record("expected .insufficientCredits, got \(error)")
                return
            }
        }
    }

    // MARK: execution error on a failed job

    private func failedJob(message: String?) -> JobDetailResponse {
        let json: String
        if let message {
            json = """
            {"id":"j","status":"failed","execution_error":{"node_id":"1",
             "node_type":"ByteDance2TextToVideoNode","exception_message":"\(message)",
             "exception_type":"Exception","traceback":[]}}
            """
        } else {
            json = #"{"id":"j","status":"failed"}"#
        }
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(JobDetailResponse.self, from: Data(json.utf8))
    }

    @Test("a partner node refusing for credits is a credit rejection")
    func executionErrorPaymentIsTyped() {
        let dto = failedJob(message: "Payment Required: Please add credits to your account to use this node.")
        guard case .serverRejected(let reason) = PollingFallback.failureError(from: dto),
              case .insufficientCredits = reason else {
            Issue.record("expected .insufficientCredits")
            return
        }
    }

    @Test("an unrelated execution failure still reports jobFailed")
    func executionErrorOtherStaysJobFailed() {
        let dto = failedJob(message: "tensor shape mismatch")
        guard case .jobFailed = PollingFallback.failureError(from: dto) else {
            Issue.record("expected .jobFailed")
            return
        }
    }

    @Test("a failure with no execution_error still reports jobFailed")
    func executionErrorMissingStaysJobFailed() {
        guard case .jobFailed = PollingFallback.failureError(from: failedJob(message: nil)) else {
            Issue.record("expected .jobFailed")
            return
        }
    }
}
