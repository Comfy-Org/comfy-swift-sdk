//
//  KeychainTokenStore.swift
//  ComfyAuthKit
//
//  The batteries-included ``ComfyTokenStore`` — a default Keychain-backed store
//  so apps don't have to hand-write the `SecItem*` boilerplate. Lives in
//  ComfyAuthKit (not the core SDK) because it imports `Security`, which the core
//  SDK's Foundation-only import boundary forbids. Apps that want full control
//  skip ComfyAuthKit and conform their own type to ``ComfyTokenStore`` instead.
//
//  Ported from the Comfy Go iOS app's KeychainStore, narrowed to the three OAuth
//  slots the ``ComfyTokenStore`` contract needs: access token, refresh token,
//  and expiry.
//
//  Accessibility is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:
//    - `ThisDeviceOnly` keeps the credential out of device backups and off any
//      other device.
//    - `AfterFirstUnlock` (NOT `WhenUnlocked`) is required because the SDK
//      performs background reattach/re-poll reads while the device is locked; a
//      `WhenUnlocked` item would fail those reads with `errSecInteractionNotAllowed`
//      even though the cloud job succeeded (rationale: KeychainStore.swift:23-34).
//
//  This file never logs the access token, refresh token, or the derived expiry.
//

import ComfySwiftSDK
import Foundation
import Security

/// A Keychain-backed ``ComfyTokenStore``: persists the OAuth token triple across launches so
/// ``ComfyAuth/restoreClient(store:config:)`` can rebuild a signed-in client without re-prompting.
///
/// The three slots (access token, refresh token, expiry) are stored as separate
/// `kSecClassGenericPassword` items under fixed account names, all sharing the configured
/// ``service``. Items are written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (see the
/// file header for why). The tokens are secrets and are never logged.
///
/// A `struct` with a single `String` property, so it is trivially `Sendable`, and each `SecItem*`
/// call is independent and thread-safe — safe to use from the concurrent contexts the SDK reads it
/// in.
public struct KeychainTokenStore: ComfyTokenStore {

    /// Caseless namespace for the three Keychain account strings. All three share ``service``.
    private enum AccountKey {
        static let accessToken  = "org.comfy.oauth.accessToken"
        static let refreshToken = "org.comfy.oauth.refreshToken"
        static let tokenExpiry  = "org.comfy.oauth.tokenExpiry"
    }

    /// Errors thrown by ``KeychainTokenStore``. The raw `OSStatus` is preserved so an unexpected
    /// Keychain failure survives into a debugger session without redaction.
    public enum KeychainError: Error, Equatable {
        /// A `SecItem*` call returned a status other than success / not-found.
        case unexpectedStatus(OSStatus)
        /// A stored value could not be decoded as UTF-8 (or a token could not be encoded as UTF-8).
        case unexpectedItemData
        /// The bundle-id-derived ``init()`` was used in a process with no `Bundle.main.bundleIdentifier`
        /// (e.g. a command-line/host process). Failing closed here avoids silently sharing a hard-coded
        /// service namespace across distinct bundle-id-less processes, which on macOS could let them read
        /// each other's OAuth tokens. Pass an explicit ``init(service:)`` in that case.
        case missingBundleIdentifier
    }

    /// The Keychain service all three slots are stored under. Configurable so tests can isolate
    /// themselves from the production keychain with a UUID-keyed value.
    public let service: String

    /// Creates a store under an explicit Keychain service namespace.
    ///
    /// - Parameter service: The Keychain service namespace for the three OAuth slots. Pass a unique
    ///   value (e.g. a UUID) in tests so the store never touches production keychain items.
    public init(service: String) {
        self.service = service
    }

    /// Creates a store under the app's bundle identifier suffixed with `.oauth`.
    ///
    /// Fails closed with ``KeychainError/missingBundleIdentifier`` when `Bundle.main.bundleIdentifier`
    /// is `nil` (e.g. a command-line/host process), rather than falling back to a shared hard-coded
    /// namespace that distinct bundle-id-less processes could use to read each other's tokens. Use
    /// ``init(service:)`` with your own namespace in that case.
    public init() throws {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            throw KeychainError.missingBundleIdentifier
        }
        self.service = bundleID + ".oauth"
    }

    // MARK: - ComfyTokenStore

    /// Returns the stored token triple, or `nil` if no complete triple is stored.
    ///
    /// All three slots must be present and the expiry must parse; a partial write (any slot
    /// missing or an unparseable expiry) is treated as "no usable session" and returns `nil` rather
    /// than a half-populated result.
    public func load() async throws -> ComfyStoredTokens? {
        guard let accessToken = try readValue(forAccount: AccountKey.accessToken),
              let refreshToken = try readValue(forAccount: AccountKey.refreshToken),
              let expiryString = try readValue(forAccount: AccountKey.tokenExpiry),
              let epoch = Double(expiryString) else {
            return nil
        }
        return ComfyStoredTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: epoch)
        )
    }

    /// Persists the token triple, replacing any previously stored tokens. The absolute ``expiresAt``
    /// is stored as an epoch-seconds string so no Foundation calendar arithmetic is involved on read.
    ///
    /// The three slots have no cross-item Keychain transaction, so this snapshots the prior triple
    /// first and, if a later write fails, best-effort rolls the already-written slots back to that
    /// snapshot before rethrowing. That prevents a mismatched (new access token, old refresh token)
    /// state that ``load()`` — which only checks presence/parseability — would return as a
    /// valid-looking but corrupt session.
    public func save(_ tokens: ComfyStoredTokens) async throws {
        let snapshot = try? currentSnapshot()
        do {
            try saveValue(tokens.accessToken, forAccount: AccountKey.accessToken)
            try saveValue(tokens.refreshToken, forAccount: AccountKey.refreshToken)
            try saveValue(
                String(tokens.expiresAt.timeIntervalSince1970),
                forAccount: AccountKey.tokenExpiry
            )
        } catch {
            // Unwind the partially-applied write back to the pre-save state, then surface the
            // original failure. Rollback is best-effort: we are already handling a Keychain error.
            restore(snapshot)
            throw error
        }
    }

    /// A raw snapshot of the three slots' stored strings (`nil` = slot absent), used to roll back a
    /// partially-applied ``save(_:)``.
    private struct Snapshot {
        let accessToken: String?
        let refreshToken: String?
        let tokenExpiry: String?
    }

    /// Reads the current stored string for each of the three slots.
    private func currentSnapshot() throws -> Snapshot {
        Snapshot(
            accessToken: try readValue(forAccount: AccountKey.accessToken),
            refreshToken: try readValue(forAccount: AccountKey.refreshToken),
            tokenExpiry: try readValue(forAccount: AccountKey.tokenExpiry)
        )
    }

    /// Best-effort restore of the three slots to `snapshot`, writing back present values and
    /// deleting slots that were absent. Failures are ignored — the caller is already unwinding a
    /// failed save and will rethrow the original error. A `nil` snapshot (couldn't be read) is a
    /// no-op.
    private func restore(_ snapshot: Snapshot?) {
        guard let snapshot else { return }
        restoreSlot(snapshot.accessToken, forAccount: AccountKey.accessToken)
        restoreSlot(snapshot.refreshToken, forAccount: AccountKey.refreshToken)
        restoreSlot(snapshot.tokenExpiry, forAccount: AccountKey.tokenExpiry)
    }

    private func restoreSlot(_ value: String?, forAccount acct: String) {
        if let value {
            try? saveValue(value, forAccount: acct)
        } else {
            try? deleteValue(forAccount: acct)
        }
    }

    /// Removes all three stored slots. Clearing an already-empty store is a no-op.
    ///
    /// All three deletions are attempted best-effort before rethrowing the first failure, so a
    /// Keychain error on an early slot does not orphan the remaining sensitive tokens.
    public func clear() async throws {
        var firstError: Error?
        for acct in [AccountKey.accessToken, AccountKey.refreshToken, AccountKey.tokenExpiry] {
            do {
                try deleteValue(forAccount: acct)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: - Private SecItem helpers

    /// Stores `value` under ``service`` + `acct`, overwriting any existing item. Re-asserts
    /// `kSecAttrAccessible` on every save.
    private func saveValue(_ value: String, forAccount acct: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.unexpectedItemData
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]

        // Add-first, fall back to update on duplicate. Probing with SecItemCopyMatching and then
        // branching to add/update would be a check-then-act (TOCTOU) race: two overlapping saves
        // for the same account could both observe errSecItemNotFound and both call SecItemAdd, with
        // the loser failing on errSecDuplicateItem. SecItemAdd is atomic, so let it arbitrate.
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Item already exists: update its data and re-assert kSecAttrAccessible on every save,
            // so an item written by a prior build under a stricter accessibility is upgraded to
            // AfterFirstUnlockThisDeviceOnly.
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainError.unexpectedStatus(status)
            }
        default:
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Returns the stored value for ``service`` + `acct`, or `nil` if no item exists.
    private func readValue(forAccount acct: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedItemData
            }
            return string
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes the item for ``service`` + `acct`. Deleting a non-existent item is treated as success.
    private func deleteValue(forAccount acct: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
