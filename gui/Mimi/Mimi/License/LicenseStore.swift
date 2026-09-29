//
//  LicenseStore.swift
//  Mimi
//

import CryptoKit
import Foundation
import Observation

/// What the app knows about the licence right now.
nonisolated enum LicenseStatus: Equatable, Sendable {
    /// No key entered.
    case unlicensed
    /// A valid key.
    case active(LicensePayload)
    /// A monthly key past its expiry but inside the offline grace period.
    case grace(LicensePayload, until: Date)
    /// A monthly key past its expiry and grace period.
    case expired(LicensePayload)
    /// A stored key that no longer verifies (for example a key from another
    /// build, or a damaged keychain entry).
    case invalid(String)

    var isLicensed: Bool {
        switch self {
        case .active, .grace: true
        default: false
        }
    }

    var payload: LicensePayload? {
        switch self {
        case .active(let p), .grace(let p, _), .expired(let p): p
        default: nil
        }
    }
}

@MainActor
@Observable
final class LicenseStore {
    private(set) var status: LicenseStatus = .unlicensed
    /// The last activation error, shown under the key field.
    private(set) var errorMessage: String?

    private let storage: any LicenseStorage
    private let publicKey: Curve25519.Signing.PublicKey?
    private let now: () -> Date

    init(
        storage: any LicenseStorage = KeychainLicenseStorage(),
        publicKey: Curve25519.Signing.PublicKey? = LicenseConfig.publicKey,
        now: @escaping () -> Date = { Date() }
    ) {
        self.storage = storage
        self.publicKey = publicKey
        self.now = now
        refresh()
    }

    /// True when this build carries a public key and can check keys.
    var canVerify: Bool { publicKey != nil }

    /// Re-reads the stored key and re-checks it (expiry moves with the clock).
    func refresh() {
        guard let stored = storage.load(), !stored.isEmpty else {
            status = .unlicensed
            return
        }
        do {
            status = evaluate(try LicenseKey.verify(stored, publicKey: publicKey))
        } catch {
            status = .invalid(error.localizedDescription)
        }
    }

    /// Checks a key and, when it is valid and not expired, stores it.
    @discardableResult
    func activate(_ text: String) -> Bool {
        errorMessage = nil
        let key = text.filter { !$0.isWhitespace }
        guard !key.isEmpty else {
            errorMessage = "Paste your licence key first."
            return false
        }
        do {
            let payload = try LicenseKey.verify(key, publicKey: publicKey)
            let result = evaluate(payload)
            if case .expired = result {
                errorMessage = "This subscription key expired on \(payload.expires?.formatted(date: .abbreviated, time: .omitted) ?? "an earlier date"). Renew it from your account page, then paste the new key."
                return false
            }
            try storage.save(key)
            status = result
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Forgets the key on this Mac.
    func remove() {
        errorMessage = nil
        do {
            try storage.delete()
            status = .unlicensed
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func evaluate(_ payload: LicensePayload) -> LicenseStatus {
        guard let expires = payload.expires else { return .active(payload) }
        let current = now()
        if current <= expires { return .active(payload) }
        let graceEnd = expires.addingTimeInterval(TimeInterval(LicenseConfig.offlineGraceDays) * 86_400)
        if current <= graceEnd { return .grace(payload, until: graceEnd) }
        return .expired(payload)
    }
}
