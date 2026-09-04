# TRAVIS Always-On Runtime

The GUI must not own long-lived work. `AlwaysOnRuntimeEngine` is a durable scheduler foundation with persisted jobs, heartbeat state, retry/backoff and pause/resume/delete controls.

## Deployment phases
1. In-process engine for integration and deterministic testing.
2. macOS LaunchAgent helper so work survives closing the GUI and restarts at login.
3. Headless service protocol so the same scheduler can move to a VPS for genuine 24/7 operation.

## Trading invariant
Existing `CryptoTradingCapability` is paper/testnet only. Always-on trading keeps that boundary. Live-money execution is not enabled by this subsystem. Before any future live connector, require a separately reviewed execution service, secret storage, exchange reconciliation, idempotent client order IDs, risk limits, daily-loss circuit breaker and remote kill switch.
