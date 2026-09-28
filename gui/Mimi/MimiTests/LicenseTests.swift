//
//  LicenseTests.swift
//  MimiTests
//

import CryptoKit
import Foundation
import Testing
@testable import Mimi

private let signer = Curve25519.Signing.PrivateKey()

private func payload(
    plan: LicensePlan = .lifetime,
    expires: Date? = nil,
    version: Int = LicensePayload.currentVersion
) -> LicensePayload {
    LicensePayload(
        v: version,
        id: "lic_test",
        email: "person@example.com",
        plan: plan,
        issued: Date(timeIntervalSince1970: 1_790_000_000),
        expires: expires,
        seats: 2
    )
}

struct LicenseKeyTests {
    @Test func aSignedKeyVerifiesOffline() throws {
        let key = try LicenseKey.make(payload(), signingWith: signer)
        #expect(key.hasPrefix("MIMI1."))
        let decoded = try LicenseKey.verify(key, publicKey: signer.publicKey)
        #expect(decoded == payload())
    }

    @Test func wrappedKeysStillVerify() throws {
        let key = try LicenseKey.make(payload(), signingWith: signer)
        let wrapped = key.enumerated().map { $0.offset % 40 == 39 ? "\($0.element)\n  " : String($0.element) }.joined()
        #expect(try LicenseKey.verify(wrapped, publicKey: signer.publicKey) == payload())
    }

    @Test func aKeySignedByAnotherKeyIsRejected() throws {
        let key = try LicenseKey.make(payload(), signingWith: Curve25519.Signing.PrivateKey())
        #expect(throws: LicenseKeyError.badSignature) {
            try LicenseKey.verify(key, publicKey: signer.publicKey)
        }
    }

    @Test func anEditedPayloadIsRejected() throws {
        let key = try LicenseKey.make(payload(), signingWith: signer)
        let parts = key.split(separator: ".").map(String.init)
        let forged = try LicenseKey.make(payload(plan: .monthly), signingWith: Curve25519.Signing.PrivateKey())
            .split(separator: ".").map(String.init)
        let spliced = [parts[0], forged[1], parts[2]].joined(separator: ".")
        #expect(throws: LicenseKeyError.badSignature) {
            try LicenseKey.verify(spliced, publicKey: signer.publicKey)
        }
    }

    @Test func garbageAndOtherVersionsAreNamed() {
        #expect(throws: LicenseKeyError.malformed) { try LicenseKey.verify("hello", publicKey: signer.publicKey) }
        #expect(throws: LicenseKeyError.unsupportedVersion("MIMI2")) {
            try LicenseKey.verify("MIMI2.abc.def", publicKey: signer.publicKey)
        }
    }

    @Test func withoutAPublicKeyNothingVerifies() throws {
        let key = try LicenseKey.make(payload(), signingWith: signer)
        #expect(throws: LicenseKeyError.noPublicKey) { try LicenseKey.verify(key, publicKey: nil) }
    }
}

@MainActor
struct LicenseStoreTests {
    private let issued = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func startsUnlicensedAndActivatesAValidKey() throws {
        let storage = MemoryLicenseStorage()
        let store = LicenseStore(storage: storage, publicKey: signer.publicKey)
        #expect(store.status == .unlicensed)
        let key = try LicenseKey.make(payload(), signingWith: signer)
        #expect(store.activate(key))
        #expect(store.status.isLicensed)
        #expect(storage.load() == key)
    }

    @Test func aBadKeyIsNotStored() {
        let storage = MemoryLicenseStorage()
        let store = LicenseStore(storage: storage, publicKey: signer.publicKey)
        #expect(!store.activate("MIMI1.nope.nope"))
        #expect(store.errorMessage != nil)
        #expect(storage.load() == nil)
        #expect(store.status == .unlicensed)
    }

    @Test func monthlyKeysGoThroughGraceThenExpire() throws {
        let expires = issued.addingTimeInterval(30 * 86_400)
        let key = try LicenseKey.make(payload(plan: .monthly, expires: expires), signingWith: signer)
        let storage = MemoryLicenseStorage(key)

        let active = LicenseStore(storage: storage, publicKey: signer.publicKey, now: { expires.addingTimeInterval(-60) })
        #expect(active.status.isLicensed)

        let grace = LicenseStore(storage: storage, publicKey: signer.publicKey, now: { expires.addingTimeInterval(86_400) })
        guard case .grace = grace.status else { Issue.record("status \(grace.status)"); return }
        #expect(grace.status.isLicensed)

        let expired = LicenseStore(storage: storage, publicKey: signer.publicKey, now: { expires.addingTimeInterval(30 * 86_400) })
        guard case .expired = expired.status else { Issue.record("status \(expired.status)"); return }
        #expect(!expired.status.isLicensed)
    }

    @Test func anExpiredKeyIsRefusedAtActivation() throws {
        let expires = issued.addingTimeInterval(30 * 86_400)
        let key = try LicenseKey.make(payload(plan: .monthly, expires: expires), signingWith: signer)
        let storage = MemoryLicenseStorage()
        let store = LicenseStore(storage: storage, publicKey: signer.publicKey, now: { expires.addingTimeInterval(60 * 86_400) })
        #expect(!store.activate(key))
        #expect(storage.load() == nil)
    }

    @Test func aStoredKeyThatNoLongerVerifiesIsReported() throws {
        let key = try LicenseKey.make(payload(), signingWith: Curve25519.Signing.PrivateKey())
        let store = LicenseStore(storage: MemoryLicenseStorage(key), publicKey: signer.publicKey)
        guard case .invalid = store.status else { Issue.record("status \(store.status)"); return }
        #expect(!store.status.isLicensed)
    }

    @Test func removingForgetsTheKey() throws {
        let key = try LicenseKey.make(payload(), signingWith: signer)
        let storage = MemoryLicenseStorage(key)
        let store = LicenseStore(storage: storage, publicKey: signer.publicKey)
        #expect(store.status.isLicensed)
        store.remove()
        #expect(store.status == .unlicensed)
        #expect(storage.load() == nil)
    }
}
