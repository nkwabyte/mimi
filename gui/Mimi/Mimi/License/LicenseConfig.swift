//
//  LicenseConfig.swift
//  Mimi
//
//  Values the owner fills in once the licence server and the store exist.
//  Nothing here is secret: the public key can only verify keys.
//

import CryptoKit
import Foundation

nonisolated enum LicenseConfig {
    /// Base64 of the licence server's Ed25519 public key (32 bytes). Empty
    /// until the key pair is generated (docs/LICENSING_PLAN.md, phase 1); an
    /// empty value means this build cannot verify keys.
    static let publicKeyBase64 = ""

    static var publicKey: Curve25519.Signing.PublicKey? {
        guard let data = Data(base64Encoded: publicKeyBase64), data.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }

    /// Checkout pages. Empty until the store is set up.
    static let lifetimeCheckoutURL = ""
    static let monthlyCheckoutURL = ""
    /// Where a customer manages a subscription or finds a lost key.
    static let customerPortalURL = ""
    static let supportEmail = ""

    /// Shown on the buttons; the checkout page is authoritative.
    static let lifetimePrice = "$29"
    static let monthlyPrice = "$5"

    /// How long a monthly key keeps working after its expiry while the app
    /// cannot reach the server to renew it.
    static let offlineGraceDays = 7

    static func url(_ text: String) -> URL? {
        text.isEmpty ? nil : URL(string: text)
    }
}
