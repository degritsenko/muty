# muty workspace rules

- Work in this repository (`degritsenko/muty`).
- Check the current branch and working tree before editing. If a branch is needed, do not use the `codex/` prefix. Keep communication concise and technical.
- After every app change, increment the build number in `VERSION`, build `dist/muty.app` with `scripts/build-app.sh`, and verify its signature with `codesign --verify --deep --strict dist/muty.app` before handing it over. Keep the release version unless a version change is requested. Setting `MUTY_RELEASE_VERSION` to the current version when running the build script increments the build number automatically.
- Run the existing checks appropriate to the change. Add or extend tests only when requested, required, or needed to catch a concrete regression. Use disposable profiles, servers, and credentials. Preserve the user's sessions, profiles, keys, password vault, and Keychain items.
- For pull request reviews, default to a concise diff review and targeted searches for obvious issues. Do not build, run tests, or create extra scenarios unless requested or the diff reveals a specific risk that needs verification.
- Before publishing, run `bash scripts/check-release.sh`, then verify the ZIP, its SHA-256 checksum, and the packaged app's signature, version, and architecture. Report skipped manual checks accurately. Leave broad GUI, sleep/wake, and Keychain-denial testing to explicit requests.
- Group changelog entries and GitHub release notes under **Added**, **Fixed**, and **Changed**. Use the matching changelog section as the source for GitHub release notes and preserve its headings. Keep validation logs out of the changelog and public release notes. Use the version without the build number in GitHub release titles.
- Prepare changes and app builds locally first. Present the changes, verification results, clickable links to README.md and CHANGELOG.md, and a proposed commit message for the user's review.
- Create commits, push commits, create or push tags, and publish GitHub releases only when the user explicitly authorizes the corresponding actions. A generic instruction such as “делай” authorizes local preparation only unless those actions are explicitly named. Do not infer publication approval from a discussion of release readiness.

## Token-efficient workflow

- Start with the task, current branch, and working-tree status. Search with `rg` or `rg --files` scoped to the relevant subsystem, then read the matching sections. Expand the scope when dependencies or findings require it.
- Reuse information already established in the current context. Re-read files when they changed, context was lost, or an exact detail needs verification.
- Read supporting documentation on demand. Use `docs/verification.md` for verification procedures and `docs/gui-checklist.md` for explicitly requested manual GUI checks.
- Keep tool output bounded. Save verbose build and check logs to a temporary file, inspect exit status, and report relevant errors or a short result. Expand output when diagnosing a failure.
- Keep changes scoped to the request. Use existing scripts and conventions. Create plans, reports, helper files, or abstractions only when requested or necessary for the task.
- Use skills whose instructions apply to the task. Keep optional workflow steps proportional to its complexity and risk, while following mandatory checks and approval requirements above.
- Before context compaction or a handoff, record a short summary of the goal, decisions, changed files, completed checks, unresolved issues, and next step in the conversation. Verify live Git and build state when resuming.
- Report changed behavior, verification results, and remaining issues concisely. Avoid repeated explanations and full logs unless requested.
