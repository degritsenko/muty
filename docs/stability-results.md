# Stability run — 2026-11-01

Status: IN PROGRESS. This is not full stability acceptance.
Baseline: 7802964, Swift 6.4 CLT, OpenSSH 10.3p1, SwiftTerm 1.20.0, Docker 29.8.2.

Checkpoint 1:
- Six deterministic regressions pass in separate processes, each with a 30-second timeout and actual case count.
- Container SSH stand binds a random loopback-only port, uses temporary generated keys/password/known_hosts, and removes its container/fixtures/agent on exit.
- Six real OpenSSH CLI checks pass: key, Unicode command, password, wrong password rejection, dedicated agent, changed host-key rejection.
- No production accounts or server configuration touched.

Commands:
- bash scripts/test.sh
- bash scripts/test-integration.sh

Important scope: CLI checks are NOT evidence that application PTY/ASKPASS/Keychain or GUI paths pass.
Remaining: encrypted-key passphrase, app PTY/ASKPASS integration, real Keychain isolation/denial checks, lifecycle and process cleanup stress, GUI matrix, terminal applications/resize/paste, sleep/wake, release gate and independent review.

Checkpoint 2:
- 8/8 named regressions: added corrupted-file preservation/read-only save and fresh identity for repeated Save as Session.
- 8/8 actual muty-askpass binary IPC checks: fragmented response, denial without secret output, zero/oversized length, truncated packet, invalid JSON, peer close, missing environment. Test fake peer is not the production AskpassBroker.
- 7/7 disposable SSH CLI cases: added encrypted identity passphrase through a test helper (not production password broker).
- Still pending: complete app PTY/broker/Keychain integration, locked real Keychain, host-key prompt UI, lifecycle stress, GUI acceptance, sleep/wake, final release/review. No production behavior change or .app version bump for these test-only changes.

Checkpoint 3:
- 10/10 named regressions now pass, plus the existing 8/8 actual-helper malformed-wire checks.
- Production AskpassBroker and compiled muty-askpass communicate over a real socket: wrong token and key-passphrase prompts cause zero credential reads, one valid password request returns a disposable secret, replay fails, stop removes socket and private directory.
- 50 broker restarts checked: previous sockets removed, capabilities unique, socket permission 0600, repeated stop safe.
- CredentialStore injection is a test seam; production default remains KeychainStore. This does not verify real Keychain or a full SSH PTY login.
- Remaining plan tasks unchanged: real Keychain, full PTY/SSH lifecycle, GUI/terminal acceptance and final independent review.

Checkpoint 4:
- Real Security.framework Keychain CRUD passed under a unique local.muty.tests.UUID service: missing/read/write/update/delete/idempotent delete. Own item cleaned with defer. User service never queried by this test.
- Real LocalProcessTerminalView PTY ran system SSH against disposable sshd with generated identity. Remote command verified stdin is a TTY, printed stty size and Unicode; exit status was zero and child PID no longer existed afterward.
- Complete run: 10/10 regressions, 8/8 helper protocol cases, 7 CLI integration cases + 1 SwiftTerm PTY case, and isolated Keychain CRUD.
- PTY command: bash scripts/test.sh && MUTY_TEST_PTY=1 bash scripts/test-integration.sh
- Keychain opt-in: .build/debug/muty-regression-tests integration.realKeychain (may cause OS access prompt; run intentionally).
- Remaining: full SSHConnection password/broker/Keychain chain, real denial/locked behavior, cancellation/network-loss cleanup, GUI/terminal matrix, sleep/wake and final review. Initial PTY test is not lifecycle stress or GUI validation.

Checkpoint 5:
- Full production path passed on disposable server: SSHConnection -> SwiftTerm PTY -> system ssh -> actual helper -> actual broker -> real isolated Keychain -> authenticated shell command output.
- Explicit disconnect removed SSH PID within bounded wait and reported Disconnected.
- Full-path wrong-password scenario exited promptly with error and no surviving SSH PID; disposable account only.
- Full run: 10 named regressions + 8 helper wire tests + 10 integration cases (7 CLI, raw SwiftTerm PTY, full correct password, full wrong password).
- SSHConnection now accepts injectable credentials and additional SSH options, with unchanged production defaults. Tests use -F /dev/null and separate known_hosts; user configuration untouched.
- Still pending: real Keychain denial/lock, cancellation in intermediate states, network loss, rapid reconnect/close races, GUI matrix, terminal acceptance/sleep-wake and final review. No stability-complete claim yet.

Checkpoint 6 — lifecycle:
- 12 immediate start/disconnect/double-disconnect cycles: all children reaped within deadline, Disconnected state stable; subsequent fresh SSH PTY login succeeded.
- Authenticated SSHConnection detected forced disposable-server termination, set an error, and reaped its child within eight seconds.
- Final suite: 10/10 regressions + 8/8 helper checks + 12/12 integration scenarios.
- Initial network-loss test failed because preceding changed-host-key test left invalid known_hosts. Test fixture now restores valid known_hosts before next scenario; rerun passed. No production fix was needed.
- Not covered yet: mid-auth prompt cancellation, true packet blackhole/keepalive timeout, simultaneous long-lived tabs, GUI Enter focus, sleep/wake. Killing the server tests transport close, not silent packet loss.

Checkpoint 7:
- Three concurrent production SSHConnections: one waiting at a real password prompt, two authenticated key sessions.
- Cancelling the password prompt and first key session reaped both PIDs; second key session remained live and executed a new command. Final disconnect reaped its PID.
- Complete rerun passed: 10 regression + 8 helper + 13 integration scenarios. User Keychain and profiles untouched by the parallel case.
- GUI Enter focus, silent network blackhole, sleep/wake and GUI/terminal acceptance remain unverified. No production changes in this checkpoint.

Checkpoint 8 — GUI focus and terminal:
- GUI on current packaged app: Enter in focused disconnected localhost:1 terminal replaced the tab/terminal instance (reconnect); Cmd-F opened find field; Enter in find field did not replace tab; Enter in sidebar search also did not reconnect. Sidebar query restored afterward. Only a temporary failed localhost tab was added.
- Expanded parallel SSHConnection scenario passed: remote stty size matched SwiftTerm rows/cols after frame resize; Ctrl-C interrupted sleep 30 and subsequent shell marker executed; 5000-line output completed and shell marker appeared.
- Full deterministic/helper/integration rerun passed (10 + 8 + 13 scenario groups). Added terminal assertions are part of the parallel scenario, not separately counted tests.
- Remaining: vim/top interactive visual checks, clipboard/large paste, silent network blackhole, sleep/wake, Keychain denial/lock and final independent review/release gate. This does not claim all GUI workflows covered.

Checkpoint 9:
- vim PTY editing/save/exit passed; synchronization waits for alternate screen and typed text rather than a fixed startup delay. Initially failed due premature test input.
- top exited back to shell; multiline PTY input markers passed. This is terminal send, not actual clipboard/UI paste or a visual rendering review.
- Silent transport loss passed via docker pause, with test-only ServerAliveInterval=1/ServerAliveCountMax=2; child exited with error. Production defaults (30s/3) are not timing-verified.
- Restart fixture now rediscovers Docker's ephemeral port and waits for SSH readiness; initial restart test failed before auth due fixture readiness/port assumptions.
- Final integration rerun: 14/14 passed. Regression/helper suite remains 10/10 + 8/8 from same test build.
- Added scripts/check-release.sh and docs/gui-checklist.md. Release gate script has syntax validation only, not yet run as a whole; remaining GUI/manual checks explicitly NOT RUN.

Mandatory release gate — COMPLETE (user reduced scope):
- bash scripts/check-release.sh succeeded: 10/10 regressions, 8/8 helper, 14/14 integration, release build, shell syntax/diff checks, plist/codesign.
- Release 0.1.4 (5). Independent read-only review: GO; no concrete blockers in stability changes, production credential defaults preserved.
- Known warnings: native SwiftPM backend deprecated; existing weak-capture diagnostic in ContentView. Not classified as release blockers.
- Optional remaining GUI/clipboard/sleep-wake/real Keychain lock-denial checks explicitly deferred by user. Do not represent them as passed.
- Future tests limited to necessary concrete bug/security/data-loss/changed-behavior cases; workspace AGENTS.md records this preference.
