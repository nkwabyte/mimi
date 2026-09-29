//
//  LicenseKey.swift
//  Mimi
//
//  The licence key format and its offline check. A key is
//
//      MIMI1.<payload>.<signature>
//
//  where <payload> is base64url JSON (LicensePayload) and <signature> is the
//  base64url Ed25519 signature of the payload bytes, made by the licence
//  server's private key. The app holds only the public key, so it can verify
//  a key without a network connection but cannot make one.
//  See docs/LICENSING_PLAN.md.
//

import CryptoKit
import Foundation

nonisolated enum LicensePlan: String, Codable, Sendable, CaseIterable {
    /// One-time purchase; never expires.
    case lifetime
    /// Monthly subscription; the key carries an expiry and is renewed by the
    /// server while the subscription is active.
    case monthly

    var title: String {
        switch self {
        case .lifetime: "Lifetime"
        case .monthly: "Monthly"
        }
    }
}

nonisolated struct LicensePayload: Codable, Sendable, Equatable {
    /// Format version of the payload.
    let v: Int
    /// Licence id on the server, e.g. "lic_01J…".
    let id: String
    let email: String
    let plan: LicensePlan
    let issued: Date
    /// When the key stops working (monthly only; nil for lifetime).
    let expires: Date?
    /// How many Macs the licence may be activated on.
    let seats: Int

    static let currentVersion = 1
}

nonisolated enum LicenseKeyError: Error, Equatable, Sendable {
    case malformed
    case unsupportedVersion(String)
    case badSignature
    case noPublicKey
}

extension LicenseKeyError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .malformed:
            "That is not a Mimi licence key. Copy the whole key from your receipt email; it starts with MIMI1."
        case .unsupportedVersion(let prefix):
            "This key (\(prefix)) was made for a newer version of Mimi. Update the app, then try again."
        case .badSignature:
            "This key could not be verified. Check that it was copied completely, or contact support."
        case .noPublicKey:
            "This build of Mimi cannot check licence keys yet."
        }
    }
}

nonisolated enum LicenseKey {
    static let prefix = "MIMI1"

    /// Parses and verifies a key. Whitespace and line breaks inside the key are
    /// ignored, so a key wrapped by an email client still works.
    static func verify(_ text: String, publicKey: Curve25519.Signing.PublicKey?) throws -> LicensePayload {
        let compact = text.filter { !$0.isWhitespace }
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw LicenseKeyError.malformed }
        guard parts[0] == prefix else {
            if parts[0].hasPrefix("MIMI") { throw LicenseKeyError.unsupportedVersion(String(parts[0])) }
            throw LicenseKeyError.malformed
        }
        guard let payloadData = base64URLDecode(parts[1]),
              let signature = base64URLDecode(parts[2]) else {
            throw LicenseKeyError.malformed
        }
        guard let publicKey else { throw LicenseKeyError.noPublicKey }
        guard publicKey.isValidSignature(signature, for: payloadData) else {
            throw LicenseKeyError.badSignature
        }
        do {
            let payload = try decoder.decode(LicensePayload.self, from: payloadData)
            guard payload.v <= LicensePayload.currentVersion else {
                throw LicenseKeyError.unsupportedVersion("payload v\(payload.v)")
            }
            return payload
        } catch let error as LicenseKeyError {
            throw error
        } catch {
            throw LicenseKeyError.malformed
        }
    }

    /// Builds a key from a payload. The app never has the private key; this is
    /// for tests and mirrors what the server does.
    static func make(_ payload: LicensePayload, signingWith key: Curve25519.Signing.PrivateKey) throws -> String {
        let data = try encoder.encode(payload)
        let signature = try key.signature(for: data)
        return "\(prefix).\(base64URLEncode(data)).\(base64URLEncode(signature))"
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode<S: StringProtocol>(_ text: S) -> Data? {
        var s = String(text)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
