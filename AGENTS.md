# muty workspace rules

- Work in this repository (`degritsenko/muty`).
- Check the current branch and working tree before editing. If a branch is needed, do not use the `codex/` prefix. Keep communication concise and technical.
- Docs and instruction edits: run `git diff --check` and verify any changed links.
- App changes: run the smallest existing check that covers the changed behavior.
  Add tests only when requested, required, or needed for a concrete regression
  or a critical security or data-loss risk.
- Build once per batch when handing over a runnable app. Bump `VERSION` once,
  run `scripts/build-app.sh`, and verify with `codesign --verify --deep --strict dist/muty.app`.
  Keep the release version unless a version change is requested. Honor explicit
  requests to defer the build and version bump.
- Run full regression or integration checks when requested, when the change
  directly affects the covered subsystem and a targeted check is insufficient,
  or as part of the release gate.
- Reuse passing results for unchanged code and inputs. If a check fails, inspect
  the relevant error and rerun the affected check after correcting the cause.
- Use disposable profiles, servers, and credentials. Preserve the user's
  sessions, profiles, keys, password vault, and Keychain items.
- For pull request reviews, default to a concise diff review and targeted searches for obvious issues. Do not build, run tests, or create extra scenarios unless requested or the diff reveals a specific risk that needs verification.
- Before publishing, run `bash scripts/check-release.sh`, then verify the ZIP, its SHA-256 checksum, and the packaged app's signature, version, and architecture. Report skipped manual checks accurately. Leave broad GUI, sleep/wake, and Keychain-denial testing to explicit requests.
- Group changelog entries and GitHub release notes under **Added**, **Fixed**, and **Changed**. Use the matching changelog section as the source for GitHub release notes and preserve its headings. Keep validation logs out of the changelog and public release notes. Use the version without the build number in GitHub release titles.
- Prepare changes and app builds locally first. Present the changes, verification results, clickable links to README.md and CHANGELOG.md, and a proposed commit message for the user's review.
- Create commits, push commits, create or push tags, and publish GitHub releases only when the user explicitly authorizes the corresponding actions. A generic instruction such as “делай” authorizes local preparation only unless those actions are explicitly named. Do not infer publication approval from a discussion of release readiness.

## Token-efficient workflow

- Start with the diff and relevant symbols. Expand scope only when a dependency
  or finding requires it.
- Keep full logs in files. Read exit status and relevant errors first.
- Keep updates to changed findings, blockers, and verification results.
