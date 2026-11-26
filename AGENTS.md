# muty workspace rules

- Work only in `degritsenko/muty` at `/Users/gritsenko/k8s/muty-public`. Check branch and status before editing, preserve unrelated changes, and use `slowhands/` for new branches. Reuse these instructions in the current chat until they change or you switch workspaces.
- Use disposable profiles, servers, and credentials for checks. Preserve user sessions, profiles, keys, the password vault, and Keychain items.
- Lead with the result or diff and relevant symbols. Keep full logs in files and report relevant checks, blockers, and skips. Link README.md and CHANGELOG.md when changed or preparing a release. Suggest a commit message for code changes.
- Use subagents for substantial independent work or review of concrete risks. Report their models and any model changes. The lead verifies findings and integrates changes.
- Get agreement before removing functionality or changing dependency sources, including vendoring or adopting a fork.

## Verification

| Scope | Required checks |
| --- | --- |
| Docs and instructions | `git diff --check` and changed links. |
| App changes | Smallest existing check covering the change. Add tests only on request, when CI or the release gate requires them, or for a concrete regression or critical security or data loss risk. Run full suites on request, when CI or the gate requires them, or when targeted checks are insufficient. |
| Runnable app handover | Build once per batch with `scripts/build-app.sh` and run `codesign --verify --deep --strict dist/muty.app`. Advance the build number in `VERSION` exactly once, accounting for script auto-increment. Keep the release version unless requested. Honor explicit build deferrals. |
| Release | Follow the [release runbook](docs/release.md). Run `bash scripts/check-release.sh` before publication. |

Reviews start with the diff and targeted searches. Build or test on request or to resolve a concrete risk. Reuse passing checks for unchanged code and inputs. Diagnose failures and rerun affected checks after fixing the cause.

## Git

Prepare locally first. Commit, push, create tags, push tags, and publish releases each require explicit authorization. “Делай” authorizes local preparation. Release-readiness discussion grants no publication authorization. Name the feature and concrete change in the commit subject. For multiple changes, explain the main changes and reasons in the body.
