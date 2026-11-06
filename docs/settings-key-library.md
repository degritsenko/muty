# Settings/key library release

Scope: Settings (Cmd+,), terminal preferences moved out of toolbar, SSH Keys registry (reference/import/rename/remove), key selection in Quick Connect and saved profiles, removal of explicit Agent and Manual Connect UI. Existing profiles remain readable; legacy agent mode remains internally compatible, editor presents Automatic.

Necessary new regression: generate disposable encrypted OpenSSH key, import without byte changes, assert 0600, reload metadata/fingerprint, validate key-ID profile, remove private copy without source deletion, remove reference without source deletion, reject public key. Existing gate passed: 11 regressions, 8 helper, 14 integration groups. After review fixes, deterministic tests and final app build rerun.

Reviewer findings: encrypted PEM fingerprint unavailable without passphrase must not block unchanged import; dependency checks now consider active identity-file auth only. No fingerprint is fabricated. SSH performs final key validation at connect. No private test/user key contents recorded in repository.

GUI smoke of newly built Settings deferred: existing muty process had user tabs; not terminated automatically. Restart explicitly to see new UI. .ppk import, generating keys and saving key passphrases are not implemented.
