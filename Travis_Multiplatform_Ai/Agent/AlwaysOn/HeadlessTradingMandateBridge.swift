import Foundation

/// Exports only non-secret standing trading permissions to the headless worker.
/// API credentials remain in Keychain and are never written to this file.
@MainActor
enum HeadlessTradingMandateBridge {
    static func synchronize(persistence: PersistenceService = .shared) {
        let granted = persistence.standingPermissions(withKeyPrefix: "trading_testnet_").filter(\.granted)
        let assets = granted.compactMap { permission -> String? in
            let prefix = "trading_testnet_"
            guard permission.key.hasPrefix(prefix) else { return nil }
            let asset = String(permission.key.dropFirst(prefix.count)).uppercased()
            return asset.isEmpty ? nil : asset
        }
        let payload: [String: Any] = [
            "version": 1,
            "updatedAt": Date().timeIntervalSince1970,
            "testnetAssets": Array(Set(assets)).sorted(),
            "liveTrading": false,
            "withdrawals": false
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let dir = base.appendingPathComponent("TRAVIS/AlwaysOn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("trading-mandates-v1.json"), options: .atomic)
    }
}
