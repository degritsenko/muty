# Productivity release verification

Implemented: English application UI/errors; nested collapsible folder tree; folder create/rename/delete (delete unfiles sessions); favorites; session move; tab duplication and drag reorder; quick connection Save as Session; native terminal find (Cmd-F); terminal font family, light/dark theme, scrollback and Option-as-Meta preferences; password/agent/identity-file auth selection. Priority-3 import/export/session restoration remain excluded.

Verified: debug build; release app build/signature; existing version-1 profile loaded without error; GUI nested QA/Nested creation/expansion, Favorites toggle, local quick connection, Cmd-F and find field, Duplicate Tab, settings menu. QA/Nested is a harmless empty test folder left in the manager. No unit tests added per user instruction.

Independent read-only review found six issues; addressed: Save-as uses fresh UUID, folder paths canonicalized, Duplicate Tab confirms changed endpoint, agent suppresses identity-file selection, password method independent of Keychain saving, persisted scrollback finite/clamped.

SSH status intentionally says SSH Running, not Connected: process existence and remote terminal output cannot reliably prove completed authentication. Accurate transport/auth state tracking remains a limitation with the current PTY-only interface. No infinite automatic retries implemented.

Not verified end-to-end in this change: identity-file and agent login, drag/drop in GUI, rename/delete subtree, live-network disconnect/reconnect, sleep/wake. Existing saved-password login had been observed in the preceding iteration. Stable signing/notarization still requires a user signing identity. No server configuration was changed.
