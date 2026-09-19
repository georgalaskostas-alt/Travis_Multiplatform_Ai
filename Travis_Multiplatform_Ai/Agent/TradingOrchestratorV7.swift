import Foundation

/// TRAVIS V7 trading decision core.
/// Intelligence can produce observations/signals, but order admission, sizing,
/// duplicate protection and portfolio constraints remain deterministic.
enum TradingOrchestratorV7 {
    enum Regime: String, Codable, CaseIterable, Hashable {
        case trend
        case range
        case volatile
        case unknown
    }

    enum SignalDirection: String, Codable, Hashable {
        case long
        case short
        case flat
    }

    struct MarketObservation: Codable, Hashable {
        var asset: String
        var timestamp: Date
        var price: Double
        var regime: Regime
        var volatilityPercent: Double
        var liquidityScore: Double
    }

    struct StrategyVote: Codable, Hashable, Identifiable {
        var id: String { "\(strategyID)::\(asset)::\(direction.rawValue)" }
        var strategyID: String
        var asset: String
        var direction: SignalDirection
        var confidence: Double
        var expectedEdgePercent: Double
        var stopDistancePercent: Double
        var evidence: [String]
    }

    struct EnsemblePolicy: Codable, Hashable {
        var minimumVotes: Int = 2
        var minimumWeightedConfidence: Double = 0.62
        var minimumExpectedEdgePercent: Double = 0.30
        var maximumVolatilityPercent: Double = 12
        var minimumLiquidityScore: Double = 0.45
        var riskFractionPerTrade: Double = 0.005
        var strategyWeights: [String: Double] = [:]
    }

    struct PortfolioPosition: Codable, Hashable {
        var asset: String
        var quantity: Double
        var averageEntry: Double
        var stopLoss: Double?
        var openedAt: Date
    }

    struct PortfolioSnapshot: Codable, Hashable {
        var mode: String
        var cash: Double
        var equity: Double
        var peakEquity: Double
        var dailyRealizedPnL: Double
        var positions: [PortfolioPosition]
        var recentOrderKeys: Set<String>
        var killSwitch: Bool

        var grossNotional: Double {
            positions.reduce(0) { partial, position in
                partial + max(0, position.quantity) * max(0, position.averageEntry)
            }
        }
    }

    struct Decision: Codable, Hashable {
        enum Action: String, Codable, Hashable {
            case buy
            case sell
            case hold
            case reject
        }

        var action: Action
        var asset: String
        var quantity: Double
        var referencePrice: Double
        var stopLossPrice: Double?
        var weightedConfidence: Double
        var expectedEdgePercent: Double
        var reasons: [String]
        var riskDecision: TradingRiskKernel.Decision?
        var idempotencyKey: String?
    }

    static func decide(
        observation: MarketObservation,
        votes: [StrategyVote],
        portfolio: PortfolioSnapshot,
        limits: TradingRiskKernel.Limits,
        policy: EnsemblePolicy = EnsemblePolicy()
    ) -> Decision {
        let asset = observation.asset.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var reasons: [String] = []

        guard observation.price.isFinite, observation.price > 0 else {
            return reject(asset: asset, price: observation.price, "Invalid reference price")
        }
        guard observation.volatilityPercent.isFinite, observation.volatilityPercent <= policy.maximumVolatilityPercent else {
            return reject(asset: asset, price: observation.price, "Volatility exceeds ensemble policy")
        }
        guard observation.liquidityScore.isFinite, observation.liquidityScore >= policy.minimumLiquidityScore else {
            return reject(asset: asset, price: observation.price, "Liquidity score below policy")
        }
        guard ["paper", "testnet"].contains(portfolio.mode.lowercased()) else {
            return reject(asset: asset, price: observation.price, "Production/live execution is intentionally unavailable")
        }
        guard !portfolio.killSwitch else {
            return reject(asset: asset, price: observation.price, "Emergency kill switch active")
        }

        let relevant = votes.filter {
            $0.asset.uppercased() == asset &&
            $0.confidence.isFinite &&
            $0.expectedEdgePercent.isFinite &&
            $0.stopDistancePercent.isFinite
        }
        guard !relevant.isEmpty else {
            return hold(asset: asset, price: observation.price, reason: "No valid strategy votes")
        }

        let grouped = Dictionary(grouping: relevant, by: \StrategyVote.direction)
        let scored = grouped.map { direction, group -> (SignalDirection, Double, Double, Int) in
            var totalWeight = 0.0
            var confidence = 0.0
            var edge = 0.0
            for vote in group {
                let weight = max(0, policy.strategyWeights[vote.strategyID] ?? 1)
                totalWeight += weight
                confidence += min(1, max(0, vote.confidence)) * weight
                edge += vote.expectedEdgePercent * weight
            }
            guard totalWeight > 0 else { return (direction, 0, 0, group.count) }
            return (direction, confidence / totalWeight, edge / totalWeight, group.count)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.3 != $1.3 { return $0.3 > $1.3 }
            return $0.0.rawValue < $1.0.rawValue
        }

        guard let winner = scored.first else {
            return hold(asset: asset, price: observation.price, reason: "No ensemble winner")
        }
        guard winner.3 >= policy.minimumVotes else {
            return hold(asset: asset, price: observation.price, reason: "Insufficient independent strategy votes")
        }
        guard winner.1 >= policy.minimumWeightedConfidence else {
            return hold(asset: asset, price: observation.price, reason: "Weighted confidence below threshold")
        }
        guard abs(winner.2) >= policy.minimumExpectedEdgePercent else {
            return hold(asset: asset, price: observation.price, reason: "Expected edge below threshold")
        }
        guard winner.0 != .flat else {
            return hold(asset: asset, price: observation.price, reason: "Ensemble is flat")
        }

        let winningVotes = grouped[winner.0] ?? []
        let medianStop = median(winningVotes.map { min(max($0.stopDistancePercent, limits.minStopDistancePercent), limits.maxStopDistancePercent) })
        let existing = portfolio.positions.first { $0.asset.uppercased() == asset }

        switch winner.0 {
        case .long:
            if existing != nil {
                return hold(asset: asset, price: observation.price, reason: "Duplicate long position blocked")
            }
            let stop = observation.price * (1 - medianStop / 100)
            let quantity = TradingRiskKernel.positionSize(
                equity: portfolio.equity,
                riskFraction: policy.riskFractionPerTrade,
                entry: observation.price,
                stop: stop,
                limits: limits
            )
            let key = orderKey(asset: asset, side: .buy, observation: observation, price: observation.price)
            let intent = TradingRiskKernel.OrderIntent(
                asset: asset,
                side: .buy,
                quantity: quantity,
                referencePrice: observation.price,
                stopLossPrice: stop,
                idempotencyKey: key
            )
            let risk = TradingRiskKernel.evaluate(intent, snapshot: riskSnapshot(portfolio), limits: limits)
            reasons.append(contentsOf: risk.reasons)
            return Decision(
                action: risk.allowed ? .buy : .reject,
                asset: asset,
                quantity: risk.allowed ? quantity : 0,
                referencePrice: observation.price,
                stopLossPrice: stop,
                weightedConfidence: winner.1,
                expectedEdgePercent: winner.2,
                reasons: reasons.isEmpty ? ["Deterministic ensemble and risk kernel approved entry"] : reasons,
                riskDecision: risk,
                idempotencyKey: key
            )

        case .short:
            guard let position = existing, position.quantity > 0 else {
                return hold(asset: asset, price: observation.price, reason: "Short signal treated as exit-only; no long position is open")
            }
            let key = orderKey(asset: asset, side: .sell, observation: observation, price: observation.price)
            let intent = TradingRiskKernel.OrderIntent(
                asset: asset,
                side: .sell,
                quantity: position.quantity,
                referencePrice: observation.price,
                stopLossPrice: nil,
                idempotencyKey: key
            )
            let risk = TradingRiskKernel.evaluate(intent, snapshot: riskSnapshot(portfolio), limits: limits)
            reasons.append(contentsOf: risk.reasons)
            return Decision(
                action: risk.allowed ? .sell : .reject,
                asset: asset,
                quantity: risk.allowed ? position.quantity : 0,
                referencePrice: observation.price,
                stopLossPrice: nil,
                weightedConfidence: winner.1,
                expectedEdgePercent: winner.2,
                reasons: reasons.isEmpty ? ["Deterministic ensemble and risk kernel approved exit"] : reasons,
                riskDecision: risk,
                idempotencyKey: key
            )

        case .flat:
            return hold(asset: asset, price: observation.price, reason: "Ensemble is flat")
        }
    }

    static func reconcile(expected: [PortfolioPosition], actual: [PortfolioPosition]) -> [String] {
        var issues: [String] = []
        let expectedMap = Dictionary(uniqueKeysWithValues: expected.map { ($0.asset.uppercased(), $0) })
        let actualMap = Dictionary(uniqueKeysWithValues: actual.map { ($0.asset.uppercased(), $0) })
        for asset in Set(expectedMap.keys).union(actualMap.keys).sorted() {
            switch (expectedMap[asset], actualMap[asset]) {
            case (nil, .some): issues.append("Unexpected external position detected for \(asset)")
            case (.some, nil): issues.append("Expected position missing for \(asset)")
            case let (.some(e), .some(a)):
                if abs(e.quantity - a.quantity) > max(0.000_000_01, abs(e.quantity) * 0.001) {
                    issues.append("Quantity mismatch for \(asset): expected \(e.quantity), actual \(a.quantity)")
                }
            case (nil, nil): break
            }
        }
        return issues
    }

    private static func riskSnapshot(_ portfolio: PortfolioSnapshot) -> TradingRiskKernel.Snapshot {
        TradingRiskKernel.Snapshot(
            mode: portfolio.mode,
            equity: portfolio.equity,
            currentPortfolioNotional: portfolio.grossNotional,
            openPositions: portfolio.positions.count,
            dailyRealizedPnL: portfolio.dailyRealizedPnL,
            peakEquity: portfolio.peakEquity,
            killSwitch: portfolio.killSwitch,
            recentOrderKeys: portfolio.recentOrderKeys
        )
    }

    private static func orderKey(asset: String, side: TradingRiskKernel.OrderIntent.Side, observation: MarketObservation, price: Double) -> String {
        let minute = Int(observation.timestamp.timeIntervalSince1970 / 60)
        let roundedPrice = String(format: "%.8f", price)
        return "v7:\(asset):\(side.rawValue):\(minute):\(roundedPrice)"
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 2 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) { return (sorted[middle - 1] + sorted[middle]) / 2 }
        return sorted[middle]
    }

    private static func hold(asset: String, price: Double, reason: String) -> Decision {
        Decision(action: .hold, asset: asset, quantity: 0, referencePrice: price, stopLossPrice: nil, weightedConfidence: 0, expectedEdgePercent: 0, reasons: [reason], riskDecision: nil, idempotencyKey: nil)
    }

    private static func reject(asset: String, price: Double, _ reason: String) -> Decision {
        Decision(action: .reject, asset: asset, quantity: 0, referencePrice: price, stopLossPrice: nil, weightedConfidence: 0, expectedEdgePercent: 0, reasons: [reason], riskDecision: nil, idempotencyKey: nil)
    }
}
