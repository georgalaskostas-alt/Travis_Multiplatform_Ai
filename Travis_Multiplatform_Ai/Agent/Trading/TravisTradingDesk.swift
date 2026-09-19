import Foundation
import Observation

// MARK: - TRAVIS Trading Desk V2
// Paper/testnet-first trading architecture. Live-money execution is intentionally not provided here.

enum TravisTradingMode: String, Codable, Sendable, CaseIterable {
    case paper
    case testnet
}

enum TravisTradeSide: String, Codable, Sendable { case buy, sell }
enum TravisOrderType: String, Codable, Sendable { case market, limit }

enum TravisTradeDecision: String, Codable, Sendable {
    case approved
    case rejected
    case requiresApproval
}

struct TravisMarketSnapshot: Codable, Sendable, Identifiable {
    let id: UUID
    let symbol: String
    let price: Double
    let timestamp: Date
    let source: String
    let indicators: [String: Double]

    init(symbol: String, price: Double, source: String, indicators: [String: Double] = [:], timestamp: Date = .now) {
        self.id = UUID(); self.symbol = symbol; self.price = price; self.timestamp = timestamp; self.source = source; self.indicators = indicators
    }
}

struct TravisTradeSignal: Codable, Sendable, Identifiable {
    let id: UUID
    let symbol: String
    let side: TravisTradeSide
    let confidence: Double
    let rationale: String
    let generatedAt: Date

    init(symbol: String, side: TravisTradeSide, confidence: Double, rationale: String) {
        self.id = UUID(); self.symbol = symbol; self.side = side; self.confidence = min(max(confidence, 0), 1); self.rationale = rationale; self.generatedAt = .now
    }
}

struct TravisOrderProposal: Codable, Sendable, Identifiable {
    let id: UUID
    let signalID: UUID
    let symbol: String
    let side: TravisTradeSide
    let type: TravisOrderType
    let quantity: Double
    let referencePrice: Double
    let stopLossPrice: Double?
    let takeProfitPrice: Double?
    let createdAt: Date

    init(signal: TravisTradeSignal, type: TravisOrderType = .market, quantity: Double, referencePrice: Double, stopLossPrice: Double?, takeProfitPrice: Double?) {
        id = UUID(); signalID = signal.id; symbol = signal.symbol; side = signal.side; self.type = type; self.quantity = quantity; self.referencePrice = referencePrice; self.stopLossPrice = stopLossPrice; self.takeProfitPrice = takeProfitPrice; createdAt = .now
    }
}

struct TravisRiskLimits: Codable, Sendable {
    var maxNotionalPerTrade: Double = 100
    var maxOpenNotional: Double = 500
    var maxDailyLoss: Double = 50
    var maxDrawdownFraction: Double = 0.10
    var maxTradesPerDay: Int = 20
    var minimumSignalConfidence: Double = 0.60
    var requireApprovalAboveNotional: Double = 50
}

struct TravisRiskAssessment: Codable, Sendable {
    let decision: TravisTradeDecision
    let reasons: [String]
    let notional: Double
}

struct TravisPaperFill: Codable, Sendable, Identifiable {
    let id: UUID
    let proposalID: UUID
    let symbol: String
    let side: TravisTradeSide
    let quantity: Double
    let price: Double
    let fee: Double
    let slippageBps: Double
    let filledAt: Date
}

struct TravisTradingMetrics: Codable, Sendable {
    var realizedPnL: Double = 0
    var fees: Double = 0
    var trades: Int = 0
    var wins: Int = 0
    var losses: Int = 0
    var peakEquity: Double = 0
    var maxDrawdown: Double = 0

    var winRate: Double { trades == 0 ? 0 : Double(wins) / Double(trades) }
}

actor TravisTradingRiskManager {
    private(set) var limits = TravisRiskLimits()
    private var killSwitch = false
    private var dailyLoss: Double = 0
    private var tradesToday: Int = 0
    private var openNotional: Double = 0

    func setKillSwitch(_ enabled: Bool) { killSwitch = enabled }
    func updateLimits(_ newLimits: TravisRiskLimits) { limits = newLimits }

    func assess(_ proposal: TravisOrderProposal, confidence: Double) -> TravisRiskAssessment {
        let notional = abs(proposal.quantity * proposal.referencePrice)
        var reasons: [String] = []
        if killSwitch { reasons.append("Trading kill switch is active") }
        if proposal.quantity <= 0 || proposal.referencePrice <= 0 { reasons.append("Invalid quantity or reference price") }
        if confidence < limits.minimumSignalConfidence { reasons.append("Signal confidence below configured minimum") }
        if notional > limits.maxNotionalPerTrade { reasons.append("Per-trade notional limit exceeded") }
        if openNotional + notional > limits.maxOpenNotional { reasons.append("Open exposure limit exceeded") }
        if dailyLoss >= limits.maxDailyLoss { reasons.append("Daily loss limit reached") }
        if tradesToday >= limits.maxTradesPerDay { reasons.append("Daily trade-count limit reached") }
        if !reasons.isEmpty { return TravisRiskAssessment(decision: .rejected, reasons: reasons, notional: notional) }
        if notional > limits.requireApprovalAboveNotional { return TravisRiskAssessment(decision: .requiresApproval, reasons: ["Human approval threshold exceeded"], notional: notional) }
        return TravisRiskAssessment(decision: .approved, reasons: ["Risk controls passed"], notional: notional)
    }

    func recordAccepted(notional: Double) { openNotional += abs(notional); tradesToday += 1 }
    func recordClosed(notional: Double, realizedPnL: Double) { openNotional = max(0, openNotional - abs(notional)); if realizedPnL < 0 { dailyLoss += abs(realizedPnL) } }
}

actor TravisPaperExecutionEngine {
    private(set) var fills: [TravisPaperFill] = []
    var simulatedFeeRate = 0.001
    var simulatedSlippageBps = 3.0

    func execute(_ proposal: TravisOrderProposal) -> TravisPaperFill {
        let direction = proposal.side == .buy ? 1.0 : -1.0
        let price = proposal.referencePrice * (1 + direction * simulatedSlippageBps / 10_000)
        let fee = abs(proposal.quantity * price) * simulatedFeeRate
        let fill = TravisPaperFill(id: UUID(), proposalID: proposal.id, symbol: proposal.symbol, side: proposal.side, quantity: proposal.quantity, price: price, fee: fee, slippageBps: simulatedSlippageBps, filledAt: .now)
        fills.append(fill)
        return fill
    }
}

@MainActor @Observable
final class TravisTradingDesk {
    static let shared = TravisTradingDesk()

    private(set) var mode: TravisTradingMode = .paper
    private(set) var lastSignal: TravisTradeSignal?
    private(set) var lastRiskAssessment: TravisRiskAssessment?
    private(set) var lastFill: TravisPaperFill?
    private(set) var metrics = TravisTradingMetrics()
    private(set) var journal: [String] = []
    private(set) var isArmed = false

    private let risk = TravisTradingRiskManager()
    private let paper = TravisPaperExecutionEngine()

    func configure(mode: TravisTradingMode) { self.mode = mode; journal.append("Mode set to \(mode.rawValue)") }
    func arm() { isArmed = true; journal.append("Trading desk armed") }
    func disarm() { isArmed = false; Task { await risk.setKillSwitch(true) }; journal.append("Trading desk disarmed / kill switch enabled") }
    func clearKillSwitch() { Task { await risk.setKillSwitch(false) }; journal.append("Kill switch cleared") }

    func evaluate(snapshot: TravisMarketSnapshot, signal: TravisTradeSignal, quantity: Double, stopLossFraction: Double = 0.02, takeProfitFraction: Double = 0.04) async -> TravisRiskAssessment {
        lastSignal = signal
        let stop = signal.side == .buy ? snapshot.price * (1 - stopLossFraction) : snapshot.price * (1 + stopLossFraction)
        let take = signal.side == .buy ? snapshot.price * (1 + takeProfitFraction) : snapshot.price * (1 - takeProfitFraction)
        let proposal = TravisOrderProposal(signal: signal, quantity: quantity, referencePrice: snapshot.price, stopLossPrice: stop, takeProfitPrice: take)
        let assessment = await risk.assess(proposal, confidence: signal.confidence)
        lastRiskAssessment = assessment
        journal.append("\(signal.symbol) \(signal.side.rawValue.uppercased()) risk=\(assessment.decision.rawValue) notional=\(String(format: "%.2f", assessment.notional))")
        guard isArmed, assessment.decision == .approved else { return assessment }
        // Both paper and testnet modes remain non-live-money. Testnet transport can replace this simulator without changing the risk gate.
        let fill = await paper.execute(proposal)
        await risk.recordAccepted(notional: assessment.notional)
        lastFill = fill
        metrics.trades += 1; metrics.fees += fill.fee
        journal.append("SIMULATED FILL \(fill.symbol) \(fill.side.rawValue.uppercased()) qty=\(fill.quantity) @ \(String(format: "%.6f", fill.price))")
        return assessment
    }
}
