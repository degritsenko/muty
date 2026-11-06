# Contributing

## Development

Requirements: macOS 14+, Swift 6.0+ and Xcode command-line tools.

```sh
swift build --build-system native
bash scripts/test.sh
```

Docker is required only for the SSH/SFTP integration gate:

```sh
MUTY_TEST_PTY=1 bash scripts/test-integration.sh
```

Before submitting a pull request:

```sh
for script in scripts/*.sh; do bash -n "$script"; done
git diff --check
bash scripts/test.sh
```

Run the full release gate with `bash scripts/check-release.sh`. It requires
Docker and verifies the built application's signature.

## Packaging

`bash scripts/build-app.sh` builds an ad-hoc-signed app using the checked-in
version and build number. To advance the build number and record a release
version after a successful build and signature verification:

```sh
MUTY_RELEASE_VERSION=0.7.1 bash scripts/build-app.sh
```

Set `SIGN_IDENTITY` to a Developer ID Application identity for distribution.

Keep changes focused. Add or extend tests only for changed behavior, concrete bug fixes, or critical security/data-loss risks. Do not use production credentials, profiles, Keychain records or remote systems in tests.

## Pull requests

Describe the user-visible behavior, security implications, verification performed and manual checks skipped. Do not commit generated builds, profiles, XML exports, credentials, private keys, logs or machine-specific paths.

Security vulnerabilities must follow `SECURITY.md` instead of public issues.
