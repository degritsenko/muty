# Changelog

All notable public changes will be documented in this file.

## 0.7.4

### Added

- Use a dedicated OpenSSH-format host-key file at `~/Library/Application Support/muty/known_hosts` for SSH sessions and jump hosts; SFTP reuses the verified SSH connection.
- Import trusted host keys explicitly from `~/.ssh/known_hosts` without modifying the source. Preserve hashed names, certificate-authority and revoked-key markers, and skip duplicate entries.
- Reveal saved session and shared-credential passwords after unlocking the vault. Hide them after 15 seconds, on selection changes, loss of focus, closing the view or locking the vault.
- Search saved credentials by name, username or host, with All, Shared and Sessions filters.

### Changed

- Move Username into Authentication and identify usernames provided by shared credentials.
- Show saved-password status and simplify credential selection labels.
- Organize the credential manager into a full-height list and a separate details pane, with actions appropriate to the selected entry.
- Move Credentials to the end of Settings and give its manager more space.
- Host-key removal affects only muty's file, preserving a backup.

## 0.7.2

### Fixed

- Make disabling the master password available through an explicit confirmation dialog.
- Set keyboard focus order in the password storage dialog.
- Show disconnected session status in a compact footer and keep password retry in the tab menu.
- Ignore authentication errors received during an intentional disconnect.

### Changed

- Outline the button set selector and separate it from command buttons.

## 0.7.1

### Fixed

- Command-W and File → Close Tab close the selected session tab.

## 0.7.0

### Added

- Initial public source release.
- Native SSH/SFTP workspace, session management, credential vault, backup/restore, SecureCRT import, tunnels, multi-pane layouts, remote editing, transfer queue, highlights and button sets.
