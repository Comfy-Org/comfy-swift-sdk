//
//  KeychainTokenStoreTests.swift
//  ComfyAuthKitTests
//
//  Round-trips KeychainTokenStore against a real (but UUID-isolated) Keychain
//  service so production items are never touched. The tests are gated on
//  `keychainAvailable`: a headless/unsigned test host (e.g. an SPM `swift test`
//  run without a usable login keychain) cannot add generic-password items and
//  reports the round-trip tests as SKIPPED rather than failed — the
//  conformance/compile coverage above still runs everywhere. On a properly
//  provisioned host (a simulator, or CI with an unlocked keychain) the full
//  round-trip runs.
//

import Testing
import Foundation
import Security
import ComfySwiftSDK
@testable import ComfyAuthKit

@Suite("KeychainTokenStore", .serialized)
struct KeychainTokenStoreTests {

    /// Whether the current test host can add/delete generic-password Keychain items. Probed once
    /// with a throwaway UUID-keyed item so the round-trip tests skip (not fail) where the Keychain
    /// is unavailable.
    static let keychainAvailable: Bool = {
        let service = "probe.comfyauthkit." + UUID().uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data("x".utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { return false }
        SecItemDelete(query as CFDictionary)
        return true
    }()

    /// A fresh store on a service no other test (or the app) uses.
    private func isolatedStore() -> KeychainTokenStore {
        KeychainTokenStore(service: "test.comfyauthkit." + UUID().uuidString)
    }

    @Test(
        "save then load returns the same token triple",
        .enabled(if: KeychainTokenStoreTests.keychainAvailable)
    )
    func saveThenLoadRoundTrips() async throws {
        let store = isolatedStore()
        // Round the expiry to whole seconds: it round-trips through an epoch-seconds string, so a
        // sub-second component would not survive and would make the equality check flaky.
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let tokens = ComfyStoredTokens(
            accessToken: "access-token-value",
            refreshToken: "refresh-token-value",
            expiresAt: expiry
        )
        do {
            try await store.save(tokens)

            let loaded = try await store.load()
            #expect(loaded?.accessToken == "access-token-value")
            #expect(loaded?.refreshToken == "refresh-token-value")
            #expect(loaded?.expiresAt == expiry)
        }
        try? await store.clear()
    }

    @Test(
        "load returns nil when nothing is stored",
        .enabled(if: KeychainTokenStoreTests.keychainAvailable)
    )
    func loadEmptyReturnsNil() async throws {
        let store = isolatedStore()
        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test(
        "save overwrites a previously stored triple",
        .enabled(if: KeychainTokenStoreTests.keychainAvailable)
    )
    func saveOverwrites() async throws {
        let store = isolatedStore()
        do {
            try await store.save(ComfyStoredTokens(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                expiresAt: Date(timeIntervalSince1970: 1_000_000_000)
            ))
            let newExpiry = Date(timeIntervalSince1970: 2_000_000_000)
            try await store.save(ComfyStoredTokens(
                accessToken: "new-access",
                refreshToken: "new-refresh",
                expiresAt: newExpiry
            ))

            let loaded = try await store.load()
            #expect(loaded?.accessToken == "new-access")
            #expect(loaded?.refreshToken == "new-refresh")
            #expect(loaded?.expiresAt == newExpiry)
        }
        try? await store.clear()
    }

    @Test(
        "clear removes the stored triple",
        .enabled(if: KeychainTokenStoreTests.keychainAvailable)
    )
    func clearRemovesTokens() async throws {
        let store = isolatedStore()
        try await store.save(ComfyStoredTokens(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_500_000_000)
        ))

        try await store.clear()

        let loaded = try await store.load()
        #expect(loaded == nil)
    }

    @Test(
        "clear on an empty store is a no-op",
        .enabled(if: KeychainTokenStoreTests.keychainAvailable)
    )
    func clearEmptyIsNoOp() async throws {
        let store = isolatedStore()
        // Must not throw even though nothing is stored.
        try await store.clear()
    }

    @Test("distinct services are isolated from each other")
    func distinctServicesAreIsolated() async throws {
        // Pure-value check that needs no Keychain: two stores built with different services must not
        // share account namespaces. This runs everywhere (no keychain gate) as a cheap guard on the
        // isolation contract the round-trip tests rely on.
        let a = KeychainTokenStore(service: "svc-a")
        let b = KeychainTokenStore(service: "svc-b")
        #expect(a.service != b.service)
    }

    @Test("default init fails closed without a bundle identifier")
    func defaultInitFailsClosedWithoutBundleID() throws {
        // The bundle-id-derived default must never silently share a hard-coded namespace across
        // processes that lack a bundle id. Branch on the host so this is deterministic everywhere:
        // an SPM `swift test` host has a nil bundle id (throws); an app/simulator host has one
        // (derives service). Runs with no keychain gate — it's a pure init-contract check.
        if let bundleID = Bundle.main.bundleIdentifier {
            let store = try KeychainTokenStore()
            #expect(store.service == bundleID + ".oauth")
        } else {
            #expect(throws: KeychainTokenStore.KeychainError.missingBundleIdentifier) {
                _ = try KeychainTokenStore()
            }
        }
    }
}
