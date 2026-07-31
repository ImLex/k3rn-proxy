import CryptoKit
import Foundation
import Security
import Supabase

/// Self-serve WireGuard onboarding. The device generates its own Curve25519
/// keypair (WireGuard's curve); the private key is stored in the Keychain and
/// never leaves the phone. Only the public key is sent to the `provision-peer`
/// Edge Function, which allocates this member's 10.8.0.x address and returns the
/// static tunnel parameters. We assemble the `.conf` locally for the user to
/// import into the WireGuard app (QR or file). Idempotent: the same stored key
/// re-provisions to the same address, so re-opening the screen is safe.
enum TunnelService {
    private static var client: SupabaseClient { SupabaseManager.client }
    private static let keyAccount = "wg_private_key"

    /// Provision (or re-provision) this device and return an importable WireGuard
    /// configuration file.
    static func provision() async throws -> WireGuardTunnel {
        let priv = loadOrCreatePrivateKey()
        let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
        do {
            let cfg: TunnelConfig = try await client.functions.invoke(
                "provision-peer",
                options: FunctionInvokeOptions(body: ProvisionRequest(public_key: pubB64))
            )
            let conf = buildConf(privateKeyB64: priv.rawRepresentation.base64EncodedString(),
                                 cfg: cfg)
            return WireGuardTunnel(assignedIP: cfg.assignedIP, confText: conf)
        } catch { throw AppError.map(error) }
    }

    // MARK: config assembly

    private static func buildConf(privateKeyB64: String, cfg: TunnelConfig) -> String {
        """
        [Interface]
        PrivateKey = \(privateKeyB64)
        Address = \(cfg.address)
        DNS = \(cfg.dns)

        [Peer]
        PublicKey = \(cfg.serverPubkey)
        Endpoint = \(cfg.endpoint)
        AllowedIPs = \(cfg.allowedIPs.joined(separator: ", "))
        PersistentKeepalive = \(cfg.keepalive)
        """
    }

    // MARK: keypair persistence (Keychain)

    private static func loadOrCreatePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let data = keychainGet(keyAccount),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        keychainSet(key.rawRepresentation, account: keyAccount)
        return key
    }

    private static func keychainGet(_ account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private static func keychainSet(_ data: Data, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

private struct ProvisionRequest: Encodable { let public_key: String }

/// Response from the provision-peer Edge Function.
struct TunnelConfig: Decodable {
    let assignedIP: String
    let address: String
    let serverPubkey: String
    let endpoint: String
    let allowedIPs: [String]
    let dns: String
    let keepalive: Int

    enum CodingKeys: String, CodingKey {
        case address, endpoint, dns, keepalive
        case assignedIP = "assigned_ip"
        case serverPubkey = "server_pubkey"
        case allowedIPs = "allowed_ips"
    }
}

/// An importable WireGuard tunnel: the assembled `.conf` text plus the assigned
/// tunnel address (for display).
struct WireGuardTunnel {
    let assignedIP: String
    let confText: String
}
