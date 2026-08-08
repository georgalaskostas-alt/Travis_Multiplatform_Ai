import Foundation

enum BinanceMarketDataError: LocalizedError {
    case requestFailed(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed(let status):
            return "Το Binance API επέστρεψε σφάλμα (\(status)) — πιθανόν άγνωστο crypto asset."
        case .invalidResponse:
            return "Μη αναμενόμενη απάντηση από το Binance API."
        }
    }
}

struct BinanceCandle {
    let openTime: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
}

/// Public Binance market-data endpoints only — no API key, no order
/// placement, no account access whatsoever. Used purely to price paper
/// trades and answer market questions.
final class BinanceMarketDataService {
    static let shared = BinanceMarketDataService()

    private let baseURL = URL(string: "https://api.binance.com/api/v3")!

    private init() {}

    /// `asset` is a bare ticker like "XRP" — always paired against USDT.
    func currentPrice(for asset: String) async throws -> Double {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("ticker/price"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "symbol", value: Self.tradingPair(for: asset))]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw BinanceMarketDataError.requestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let priceString = json["price"] as? String,
            let price = Double(priceString)
        else {
            throw BinanceMarketDataError.invalidResponse
        }

        return price
    }

    /// Recent OHLCV candles — not required for placing a paper trade, but
    /// useful context for conversational market questions.
    func recentCandles(for asset: String, interval: String = "1h", limit: Int = 24) async throws -> [BinanceCandle] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("klines"), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: Self.tradingPair(for: asset)),
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw BinanceMarketDataError.requestFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else {
            throw BinanceMarketDataError.invalidResponse
        }

        return rows.compactMap { row in
            guard
                row.count >= 6,
                let openTimeMs = row[0] as? Double,
                let open = Double(row[1] as? String ?? ""),
                let high = Double(row[2] as? String ?? ""),
                let low = Double(row[3] as? String ?? ""),
                let close = Double(row[4] as? String ?? ""),
                let volume = Double(row[5] as? String ?? "")
            else { return nil }

            return BinanceCandle(
                openTime: Date(timeIntervalSince1970: openTimeMs / 1000),
                open: open, high: high, low: low, close: close, volume: volume
            )
        }
    }

    private static func tradingPair(for asset: String) -> String {
        asset.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() + "USDT"
    }
}
