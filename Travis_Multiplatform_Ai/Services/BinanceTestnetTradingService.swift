import Foundation
import CryptoKit

enum BinanceTestnetTradingError: LocalizedError {
    case missingCredentials
    case requestFailed(status: Int, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Δεν έχουν οριστεί Binance Testnet API Key/Secret. Πρόσθεσέ τα στις Ρυθμίσεις."
        case .requestFailed(let status, let message):
            return "Το Binance Testnet API επέστρεψε σφάλμα (\(status))\(message.isEmpty ? "" : ": \(message)")."
        case .invalidResponse:
            return "Μη αναμενόμενη απάντηση από το Binance Testnet API."
        }
    }
}

struct BinanceTestnetOrderResult {
    /// Actual filled quantity/price Binance reports — never assume this
    /// matches the requested quantity or the last-seen market price
    /// exactly, a MARKET order fills at whatever the book offers.
    let filledQuantity: Double
    let filledPrice: Double
}

enum BinanceTestnetOrderSide: String {
    case buy = "BUY"
    case sell = "SELL"
}

/// Real order execution against Binance's SPOT TESTNET only —
/// testnet.binance.vision, never the production API, never referenced
/// anywhere near a live/real-money endpoint. Funds are fictitious,
/// provided by Binance's own testnet faucet; this service places
/// genuine HMAC-signed orders against them, but there is no path from
/// here to a real account. Credentials come from `KeychainService`'s
/// `binanceTestnetAPIKey`/`binanceTestnetAPISecret` — entered separately
/// from, and clearly labeled apart from, any future live-trading
/// credential (see `SettingsView`).
final class BinanceTestnetTradingService {
    static let shared = BinanceTestnetTradingService()

    private let baseURL = URL(string: "https://testnet.binance.vision")!

    private init() {}

    /// Places a MARKET order and returns what actually filled.
    func placeMarketOrder(asset: String, side: BinanceTestnetOrderSide, quantity: Double) async throws -> BinanceTestnetOrderResult {
        guard
            let apiKey = KeychainService.shared.binanceTestnetAPIKey, !apiKey.isEmpty,
            let apiSecret = KeychainService.shared.binanceTestnetAPISecret, !apiSecret.isEmpty
        else {
            throw BinanceTestnetTradingError.missingCredentials
        }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        var params = [
            ("symbol", Self.tradingPair(for: asset)),
            ("side", side.rawValue),
            ("type", "MARKET"),
            ("quantity", Self.formatQuantity(quantity)),
            ("timestamp", String(timestamp))
        ]
        let queryString = params.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        params.append(("signature", Self.sign(queryString, secret: apiSecret)))

        var components = URLComponents(url: baseURL.appendingPathComponent("api/v3/order"), resolvingAgainstBaseURL: false)!
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-MBX-APIKEY")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BinanceTestnetTradingError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BinanceTestnetTradingError.requestFailed(status: httpResponse.statusCode, message: Self.errorMessage(from: data))
        }

        return try Self.parseOrderResult(from: data)
    }

    private static func sign(_ payload: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// Binance's order response reports individual fills under "fills"
    /// (each with its own price/qty, since a MARKET order can match
    /// multiple resting orders at different prices) — prefer the
    /// volume-weighted average across those when present, since that's
    /// the true effective entry/exit price. Falls back to the aggregate
    /// executedQty/cummulativeQuoteQty fields otherwise.
    private static func parseOrderResult(from data: Data) throws -> BinanceTestnetOrderResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BinanceTestnetTradingError.invalidResponse
        }

        if let fills = json["fills"] as? [[String: Any]], !fills.isEmpty {
            var totalQty = 0.0
            var totalQuote = 0.0
            for fill in fills {
                guard
                    let priceString = fill["price"] as? String, let price = Double(priceString),
                    let qtyString = fill["qty"] as? String, let qty = Double(qtyString)
                else { continue }
                totalQty += qty
                totalQuote += price * qty
            }
            guard totalQty > 0 else { throw BinanceTestnetTradingError.invalidResponse }
            return BinanceTestnetOrderResult(filledQuantity: totalQty, filledPrice: totalQuote / totalQty)
        }

        guard
            let executedQtyString = json["executedQty"] as? String, let executedQty = Double(executedQtyString), executedQty > 0,
            let cumulativeQuoteString = json["cummulativeQuoteQty"] as? String, let cumulativeQuote = Double(cumulativeQuoteString)
        else {
            throw BinanceTestnetTradingError.invalidResponse
        }

        return BinanceTestnetOrderResult(filledQuantity: executedQty, filledPrice: cumulativeQuote / executedQty)
    }

    private static func errorMessage(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["msg"] as? String
        else { return "" }
        return message
    }

    private static func tradingPair(for asset: String) -> String {
        asset.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() + "USDT"
    }

    private static func formatQuantity(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
