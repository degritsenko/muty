# Session Tab Settings and SFTP Properties

## Intent
Expose session settings from the active tab and make remote file metadata and Unix permissions easier to inspect and edit.

## Goals
- Add a tab context-menu item that edits saved sessions through the existing profile editor.
- Let temporary Quick Connect and Local Shell tabs edit their own settings. Reconnect only when connection-defining fields change. Keep these edits local to that tab.
- Replace the SFTP `Permissions…` octal prompt with a `Properties…` window showing name, remote path, type, size, modification time, numeric owner/group IDs and Unix permissions.
- Edit permission bits through owner/group/other read-write-execute checkboxes and an octal field. Apply changes through existing SFTP chmod validation.

## Constraints
- Preserve existing behavior for saved-session edits and temporary tab identity.
- Display only metadata available from SFTP attributes. Owner/group IDs are read-only because current client has no chown implementation.
- Reject malformed octal input and preserve supported special permission bits when users edit ordinary permission checkboxes.
- Run existing regression checks and signed app build. Do not commit or publish.

## Approaches
Use the existing `ProfileEditor` for saved sessions. For temporary tabs, use a tab-scoped settings draft and update/reconnect only that tab. For file properties, replace the alert with a focused SwiftUI sheet and reuse `currentPermissions`, `changePermissions`, and `SFTPAttributes`.

## Decisions
The user approved tab-scoped settings for saved and temporary sessions, with reconnect when transport settings change. The user approved SFTP Properties modeled on the supplied reference. Metadata without a supported SFTP mutation remains read-only.
