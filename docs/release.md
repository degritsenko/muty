# Release runbook

- Before publishing, run `bash scripts/check-release.sh` from the repository root.
- Verify the release ZIP and SHA-256 checksum. Unpack the ZIP and verify the app signature, version, and architecture.
- Report skipped manual checks and include validation logs in the handover. Broad GUI, sleep/wake, and Keychain-denial checks require an explicit request.
- Group changelog entries and release notes under **Added**, **Fixed**, and **Changed**. Derive release notes from the matching changelog section and preserve its headings.
- Include the release version and substantive change in the release commit. Use the version without a build number in the release title.
