# Session Tabs and SFTP Properties Implementation Plan

**Goal:** Add per-tab access to session settings and a file Properties editor to the remote SFTP pane.

**Architecture:** Reuse `ProfileEditor` and `AppModel.save` for saved sessions. Add a temporary-session editor path that updates only one connection and reconnects when transport configuration changes. Replace the permissions alert with a sheet backed by existing SFTP metadata and chmod APIs.

**Tech Stack:** SwiftUI, AppKit, existing SFTP v3 client.

**Spec:** [2026-11-10-session-tabs-and-sftp-properties-design.md](../specs/2026-11-10-session-tabs-and-sftp-properties.md)

## Global Constraints
- Preserve existing authentication, workspace tab naming, and saved-profile behavior.
- Owner/group are read-only numeric IDs.
- Build and sign `dist/muty.app`, incrementing build number only.
- No commit, push, tag, or publication.

## Review Focus
- Saving a temporary tab edit changes only the selected temporary tab.
- Transport changes reconnect and preserve tab identity/name.
- Appearance-only changes update the existing terminal without credential revocation.
- Permission checkbox edits remain synchronized with octal mode and validate special bits.
- Missing metadata renders as unavailable without blocking properties display.

## Files
- `Sources/muty/ContentView.swift` adds tab menu access.
- `Sources/muty/AppModel.swift` applies temporary edits and reconnects selectively.
- `Sources/muty/ProfileEditor.swift` supports a tab-scoped editing callback.
- `Sources/muty/SFTPBrowserView.swift` presents Properties and permission controls.
- `Sources/muty/SFTPBrowserModel.swift` fetches complete current file metadata for the sheet.
- `Tests/MutyTests/RegressionTests.swift` covers session edit classification and permission mode parsing if a pure helper is introduced.
- `README.md`, `CHANGELOG.md`, and `VERSION` are updated for the feature and local build.

## Tasks

### Task 1: Session Settings from tabs
- [ ] Add `Session Settings…` to tab context menu for saved and temporary sessions.
- [ ] Saved sessions open the existing editor.
- [ ] Temporary sessions open an editor whose save callback updates only the original connection profile.
- [ ] Reconnect temporary sessions when host, user, authentication, key, or SSH/SFTP mode changes. Preserve tab name and identity.
- [ ] Apply color/theme changes live without reconnecting.
- [ ] Add focused regression checks for saved/temporary routing and selective reconnect.

### Task 2: SFTP Properties
- [ ] Fetch `SFTPAttributes` and show metadata in a Properties sheet.
- [ ] Build a permission editor with octal field, owner/group/other checkboxes, and special bits.
- [ ] Validate octal mode and apply with existing safe `setPermissions` API.
- [ ] Add focused tests for mode parsing/checkbox synchronization where practical.

### Task 3: Verify and package
- [ ] Update README and Unreleased changelog.
- [ ] Increment VERSION build, build the app, verify signing.
- [ ] Run regression suite and report skipped manual checks.
