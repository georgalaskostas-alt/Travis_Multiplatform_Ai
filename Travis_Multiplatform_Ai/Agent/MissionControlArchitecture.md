# TRAVIS Mission Control Architecture

## Runtime lifecycle
TRAVIS persists `AgentTask` snapshots atomically through `AgentTaskStore`. Mission history deletion is performed by the store and protects active task IDs. `MissionRetentionPolicy` and `RuntimeMaintenance` bound long-term finished-task history without removing active missions.

## Cross-device control
The Mac is the authoritative runtime while the iPhone acts as a live control surface. `TravisDeviceBridgeService` transports status snapshots and deterministic remote commands. Mission controls bypass natural-language routing.

## Progress
`MissionProgressSummary` provides a shared semantic representation of completed/total steps, percentage, current step and next step. Cross-device snapshots expose detailed step state for the iPhone Mission Control UI.

## Events and completion
`MissionEventCenter` is the in-app event foundation for completion, failure and warning surfaces. iOS completion/failure notification delivery remains integrated at the root synchronization layer.

## Diagnostics
`RuntimeHealthScanner` checks runtime freshness, stored failures and iPhone-to-Mac bridge state. `RuntimeDiagnostics` creates a compact runtime snapshot suitable for a future diagnostics UI/export.

## Safety invariants
- Active missions are never bulk-deleted by history cleanup.
- Remote task controls use deterministic commands rather than AI interpretation.
- Runtime persistence uses atomic snapshot writes.
- Mission history has a bounded retention policy.
- Mac remains the authoritative executor for Mac-originated missions.
