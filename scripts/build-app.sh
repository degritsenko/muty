#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
read -r version build < VERSION
if [[ -n "${MUTY_RELEASE_VERSION:-}" ]]; then
    version="$MUTY_RELEASE_VERSION"
    build="$((build + 1))"
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf '%s\n' 'Invalid release version.' >&2; exit 1; }
swift build --build-system native -c "$configuration"
bin="$(swift build --build-system native -c "$configuration" --show-bin-path)"
app="$PWD/dist/muty.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
rm -f "$app/Contents/MacOS/muty-sftp" "$app/Contents/Resources/OpenSSH-LICENSE"
install -m 755 "$bin/muty" "$app/Contents/MacOS/muty"
install -m 755 "$bin/muty-askpass" "$app/Contents/MacOS/muty-askpass"
install -m 755 "$bin/muty-ssh-proxy" "$app/Contents/MacOS/muty-ssh-proxy"
install -m 644 "$PWD/Sources/SecureCRTSupport/LICENSE" "$app/Contents/Resources/SecureCRTSupport-LICENSE"
install -m 644 "$PWD/.build/checkouts/SwiftTerm/LICENSE" "$app/Contents/Resources/SwiftTerm-LICENSE"
install -m 644 "$PWD/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
for bundle in "$bin"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done
# Bundle.main resolves SwiftUI/AppKit localizations from .lproj directories at the app's
# resource root, so copy them there in addition to the SwiftPM resource bundle.
for lproj in "$PWD/Sources/muty/Resources"/*.lproj; do
    [[ -d "$lproj" ]] || continue
    ditto "$lproj" "$app/Contents/Resources/$(basename "$lproj")"
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>muty</string>
<key>CFBundleDisplayName</key><string>muty</string>
<key>CFBundleExecutable</key><string>muty</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleIdentifier</key><string>local.muty.app</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.muty.sftp-items</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
<key>UTTypeDescription</key><string>muty remote file selection</string>
</dict></array>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$app/Contents/Info.plist"
identity="${SIGN_IDENTITY:--}"
codesign --force --sign "$identity" --identifier local.muty.askpass "$app/Contents/MacOS/muty-askpass"
codesign --force --sign "$identity" --identifier local.muty.ssh-proxy "$app/Contents/MacOS/muty-ssh-proxy"
codesign --force --sign "$identity" --identifier local.muty.app "$app"
codesign --verify --deep --strict "$app"
if [[ -n "${MUTY_RELEASE_VERSION:-}" ]]; then
    printf '%s %s\n' "$version" "$build" > VERSION
fi
printf '\nmuty %s (%s)\n%s\n' "$version" "$build" "$app"
