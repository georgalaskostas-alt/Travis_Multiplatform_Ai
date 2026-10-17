# TRAVIS V1 Release Candidate

Release candidate baseline: 2026-09-26

## Version
- App marketing version: 1.0
- Build: 1
- Always-On worker: v5.1 / schema 12

## Acceptance status
- macOS build: PASS
- iPhone build, install and launch: PASS
- Natural-language Mission V2 routing without /plan: PASS
- Always-On headless handoff and execution: PASS
- Timed 2-minute runtime monitoring: PASS
- Final report synthesis and reconciliation: PASS
- iPhone Task Control terminal state: COMPLETED, 2/2, 100%
- Secure LAN pairing and Control Plane command path: PASS
- Remote pause, resume and cancel: PASS
- Restart/recovery path: PASS
- Emergency Stop: PASS

## Security hardening included
- Device-only Keychain accessibility for credentials.
- Checked and atomic credential replacement.
- Sanitized GitHub, AI-provider, Supabase/OAuth and Control Plane errors.
- Sensitive-value redaction in Always-On worker journals.
- Durable/idempotent Control Plane receipts and fail-closed command persistence.
- No production trading or withdrawal execution in the Always-On worker.

## Release notes
The installer uses Tools/travis_runtime_worker_v5.py. Older worker files are retained as historical/migration artifacts and are not installed by the current launcher.

The current OAuth flow is working and accepted for V1. A future hardening iteration may migrate the OAuth exchange to PKCE after dedicated compatibility testing.

Runtime health reports should be reviewed operationally. In the final acceptance run, the runtime reported low free disk space; this is an environment condition rather than an application acceptance failure.
