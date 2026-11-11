# Changelog

## 0.7.11

### Added

- Send Ctrl+C from a Button Bar button with the `\x03` escape.
- Search saved sessions by folder path.
- Give each split pane its own tab group. Drag live tabs between panes and restore saved groups after relaunch.
- Add the Two Left + Right layout to the Window menu.
- Save named SFTP bookmarks for pairs of local and remote directories.
- Choose a session for each split pane and remember the selected Button Bar for each open tab.

### Fixed

- Cycle through visible panes with Ctrl+Tab and Ctrl+Shift+Tab in split layouts.
- Prevent a crash when closing the last Local Shell tab.
- Preserve folder colors when saving changes to the session catalog. Thanks to @zurkiryy for PR #6.
- Restore folder colors from backups and retain local colors for folders absent from the backup. Thanks to @zurkiryy for PR #7.

## 0.7.10

### Added

- Color folders with the session palette. Nested folders inherit their nearest colored parent unless assigned their own color.
- Use one font size for the saved-session and terminal search fields.
- Open session settings from a tab, including temporary Quick Connect and Local Shell tabs. Apply appearance changes immediately and reconnect temporary sessions when connection settings change.
- Inspect SFTP file metadata and edit Unix permissions from a Properties window.
- Name new Local Shell tabs after the machine hostname.

- Forget saved passwords for selected SSH sessions through Bulk Edit, with confirmation and shared credential unlinking.

- Assign session colors and terminal themes through Bulk Edit. Override the global terminal theme per session, with inheritance by default and immediate updates to open terminals. Preserve overrides in configuration backups.

- Choose from 16 built-in terminal color schemes, applied to open and new sessions. Preserve the original Dark and Light appearances as Muty Dark and Muty Light.

### Fixed

- Preserve split pane assignments when temporary session settings restart a connection. Use the same tab replacement flow for session settings and reconnect.
- Keep pending authentication intact when Bulk Edit changes only appearance. Update open-tab colors immediately and inherit the global theme for unknown imported scheme IDs.

### Changed

- Thank you to @zurkiryy for contributing built-in terminal color schemes in PR #3.
- Thank you to @zurkiryy for contributing the SFTP transfer queue improvements in PR #4.

## 0.7.9

### Added

- Keep backup and restore logs open with operation details, results and Copy Log.
- Pause and resume the current SFTP transfer between data blocks.
- Pin Session Manager as a sidebar that resizes the terminal. Remember its pinned state between launches.
- Search saved sessions when choosing the startup session. Choose an empty window, Local Shell or Quick Connect when no startup session or restored tabs are available.
- Reveal the master password during setup, unlock and password changes. Disable the master password from a dedicated menu action.

### Fixed

- Preview the actual sessions, folders and passwords to be added, replaced or kept before restoring a backup.
- Keep Session Manager open during session deletion and return focus to its search field afterward.
- Show the effective username from shared credentials in Quick Connect.
- Distinguish paused transfers from cancelled jobs. Offer Retry Failed after cancellation and allow clearing failed or cancelled transfers.

### Changed

- Show Session Manager search results in their folder tree, with matching branches expanded.
- Allow hiding the SFTP transfer list during copying, reduce transfer-panel height and always show hidden files.
- Include the server in remote editor and viewer window titles and file paths.
- Add the local date in dd-MM-yyyy format to backup filenames. Identify sessions and shared credentials in export logs.
- Leave the Quick Connect username empty by default.
- Reorder Settings sections, clarify Link Key File and Import Key Copy actions, and remove the connection menu from the toolbar.
- Hide Session Manager when it is unpinned.

## 0.7.8

### Added

- Select one of the first nine session tabs with ⌘1–9. Numbered labels show which shortcut selects each tab.

### Fixed

- Scroll the selected session tab into view when it falls outside the visible tab strip.
- Keep authentication controls in a consistent order when switching methods in Quick Connect.
- Show Disconnected when an SSH session ends or is stopped. Remove the generic error banner for SSH process exits while retaining specific errors.

### Changed

- Cycle through session tabs with Ctrl+Tab and Ctrl+Shift+Tab.
- Collapse completed SFTP transfers to a summary with Show and Clear. Expand the queue automatically when a transfer fails.
- Choose a library key or private-key file from one menu in Quick Connect. In password mode, choose between entering a password when prompted and using shared credentials.
- Keep connection state on the left of the status bar and fit destination, jump host and SSH details on the right as space allows.

## 0.7.7

### Added

- Foreground keyword highlighting with configurable literal and regex rules, legacy-rule migration, and View → Highlight Output (⇧⌘H). Thanks to @zurkiryy for [PR #1](https://github.com/degritsenko/muty/pull/1).
- Optional status bar showing connection state, destination, negotiated SSH cipher and jump host. Toggle it with View → Status Bar.
- Choose a private-key file directly in Quick Connect without adding it to the key library, with permission checks before connecting.

### Fixed

- Interrupt slow highlight regular expressions with a processing-time budget to keep the interface responsive.

### Changed

- Move Settings to File and remove Services from the application menu.
- Move SSH/SFTP switching into the session-tab row and reduce tab height and padding.
- Replace large session-state icons with compact green, yellow and red dots.
- Separate saved-session and terminal search fields with additional spacing and a divider.

## 0.7.6

### Added

- Search saved sessions by name or host from the toolbar next to terminal search, with suggestions, arrow-key navigation and Enter to connect.

### Fixed

- Hide the transfer panel immediately after clearing the last completed transfers.
- Close remote editor and viewer tabs with Escape, preserving the existing unsaved-change confirmation.
- Exclude folder names from Session Manager search and use the same matching rules as toolbar session search.
- Hide session suggestions when no hosts match.

### Changed

- Move the Button Bar set selector to the right, after the add button.

## 0.7.5

- Open remote text files in tabs within one editor window per SFTP session.
- Wrap long lines in the remote editor and insert spaces when pressing Tab in YAML files.
- Open Settings in a compact, resizable modal window that closes with Escape.

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
