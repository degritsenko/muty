# Stability acceptance matrix

PASS means observed, not inferred from code or unit tests.

| Scenario | State | Evidence |
|---|---|---|
| Enter reconnect in focused disconnected terminal | PASS | GUI checkpoint 8 |
| Enter in terminal find / sidebar search does not reconnect | PASS | GUI checkpoint 8 |
| Nested tree/root move | USER VERIFIED | User screenshots and feedback |
| Single-item drag preview after favorite identity fix | NOT RUN | Needs visual check |
| Duplicate/reorder tab gestures | PARTIAL | Duplicate observed previously; reorder gesture not verified |
| Folder subtree rename/delete | NOT RUN | Model tests insufficient for GUI |
| Cmd-F focus and find input | PASS | GUI checkpoint 8 |
| Cmd+/−/0 in terminal/search | NOT RUN | Need GUI |
| Saved-password auth and disconnect | PASS | Full SSHConnection integration |
| Identity / encrypted identity / agent | PARTIAL | Real CLI; raw identity PTY passed |
| Password cancellation / parallel tabs | PASS | Full SSHConnection integration |
| Sleep/wake macOS | NOT RUN | Requires consent to disrupt device |
| Real Keychain lock/deny | NOT RUN | Do not lock user Keychain silently |
| Clipboard and large paste | NOT RUN | Multiline send is not clipboard verification |
| Large output / Ctrl-C / remote PTY resize | PASS | Full SSHConnection terminal scenario |

Automated gate: `bash scripts/check-release.sh`. This rebuilds .app and advances VERSION.
