# muty workspace rules

- Work in this repository (`degritsenko/muty`).
- Check the current branch and working tree before editing. If a branch is needed, do not use the `codex/` prefix. Keep communication concise and technical.
- After every app change, increment the build number in `VERSION`, build `dist/muty.app` with `scripts/build-app.sh`, and verify its signature with `codesign --verify --deep --strict dist/muty.app` before handing it over. Keep the release version unless a version change is requested. Setting `MUTY_RELEASE_VERSION` to the current version when running the build script increments the build number automatically.
- Run the existing checks appropriate to the change. Add or extend tests only when requested, required, or needed to catch a concrete regression. Use disposable profiles, servers, and credentials. Preserve the user's sessions, profiles, keys, password vault, and Keychain items.
- Before publishing, run `bash scripts/check-release.sh`, then verify the ZIP, its SHA-256 checksum, and the packaged app's signature, version, and architecture. Report skipped manual checks accurately. Leave broad GUI, sleep/wake, and Keychain-denial testing to explicit requests.
- Group changelog entries under **Added**, **Fixed**, and **Changed**. Keep validation logs out of the changelog and public release notes. Use the version without the build number in GitHub release titles.
- Push commits or tags and publish GitHub releases only when the user explicitly requests those actions.
