# TRAVIS Trading Desk V2 — acceptance gates

The trading subsystem is intentionally paper/testnet-first. A live-money exchange adapter is not enabled by this change.

## Architecture
Market Intelligence → Strategy Signal → Risk Manager → Order Proposal → Paper/Testnet Execution → Journal/Analytics.

## Mandatory gates before any live-money adapter
1. Always-On worker acceptance passes after GUI termination/relaunch.
2. Remote kill switch is independently testable.
3. Credential material is Keychain/server-secret only; never persisted in source/runtime JSON.
4. Backtest includes fees and slippage and reports drawdown, profit factor, expectancy, win/loss counts.
5. Forward test on exchange testnet/paper environment passes defined loss/exposure limits.
6. Real-money execution requires a separate explicit implementation and review.

## Current implementation
- `TravisTradingDesk`: paper/testnet mode, arm/disarm, hard risk gate, human-approval threshold, kill switch, simulated fills and journal.
- `TravisTradingRiskManager`: max trade/open exposure/daily loss/trade count/min confidence.
- `TravisPaperExecutionEngine`: deterministic fee/slippage simulation.
- `TravisBacktestEngine`: deterministic long/flat backtest metrics.
- Control-plane protocol/models and local durable mirror are present for secure cloud transport integration.
