# muty

Native, local-first SSH and SFTP workspace for macOS. No account or cloud service required.

![Active SSH terminal session connected to a demo Alpine Linux server](docs/ssh-session.png)

- SSH and local shell tabs with split layouts.
- Two-pane SFTP browser, transfer queue and remote text editor.
- Saved sessions, folders and shared credentials.
- Jump hosts, port forwarding and tunnel-only sessions.
- SecureCRT and MobaXterm session import.
- Local credential vault and encrypted backups.

![muty connected to a demo SSH server, showing two-pane SFTP and a completed upload](docs/screenshot.png)

## Download

muty requires Apple silicon (arm64) and macOS 14 or later. Download the app ZIP from the [latest GitHub release](https://github.com/degritsenko/muty/releases/latest), unzip it, and move `muty.app` to Applications.

The app is ad-hoc signed and has not been notarized. If macOS blocks the app and you trust the download, go to **System Settings → Privacy & Security → Open Anyway** after the first launch attempt and confirm. macOS saves an exception for muty. [Apple Support](https://support.apple.com/en-us/102445)

## Build from source

Requires macOS 14 or later and an Xcode toolchain with Swift 6.0 or later. Clone this repository and run the following commands from its root.

```sh
bash scripts/build-app.sh
open dist/muty.app
```

See [Contributing](CONTRIBUTING.md) for development and testing, [Security](SECURITY.md) for vulnerability reporting, and [Privacy](PRIVACY.md) for local data handling.

Original code is licensed under [Apache-2.0](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md).
