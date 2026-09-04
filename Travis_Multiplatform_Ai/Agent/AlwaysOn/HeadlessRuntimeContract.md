# TRAVIS Headless Runtime Contract

The LaunchAgent worker owns service heartbeat, safe service-job scheduling, leases, crash recovery and an append-only journal independently of the GUI process.

## Safety boundary

The worker never evaluates arbitrary shell payloads. Current executable kinds are `heartbeatProbe` and a local deterministic `watcher` cycle. Mission V2 remains app-owned until its Swift dependencies are extracted into a headless executable. Trading is not executed by this Python worker. Existing trading remains paper/testnet-only and must later move behind a dedicated connector + risk engine before continuous execution.

## Durability

- `service-jobs-v1.json`: worker-owned jobs
- `service-journal-v1.jsonl`: append-only lifecycle journal
- `worker-heartbeat.json`: liveness/status
- `worker-control.json`: persisted kill switch
- running jobs receive a time-bounded lease; stale leases recover to scheduled after restart

This separation prevents duplicate execution and avoids falsely treating GUI mission state as process-independent.
