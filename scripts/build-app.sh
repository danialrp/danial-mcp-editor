#!/bin/bash
# Builds "Danial MCP Editor.app" into build/ (git-ignored), without Xcode.
#
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-release}"
scripts/swift.sh build -c "$config" --product DanialMCPEditor
bin="$(scripts/swift.sh build -c "$config" --product DanialMCPEditor --show-bin-path)/DanialMCPEditor"

app="build/Danial MCP Editor.app"
mkdir -p build
if [[ -d "$app" ]]; then trash "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/DanialMCPEditor"
# Built-in effect plug-ins: folders of a manifest and Metal source.
cp -R Effects "$app/Contents/Resources/Effects"
# The agent guide, served by the agent.guide tool.
cp docs/agent-guide.md "$app/Contents/Resources/agent-guide.md"
# The app icon, made from Assets/AppIcon.svg by scripts/make-icon.sh.
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

version="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/EditorKit/Editor.swift)"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Danial MCP Editor</string>
    <key>CFBundleDisplayName</key><string>Danial MCP Editor</string>
    <key>CFBundleIdentifier</key><string>app.danialmcpeditor.editor</string>
    <key>CFBundleExecutable</key><string>DanialMCPEditor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleVersion</key><string>${version}</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Records voice-over onto the timeline.</string>
</dict>
</plist>
EOF

# Ad-hoc signature for running where it was built. The hardened runtime needs
# the audio-input entitlement for voice-over recording.
entitlements="$(mktemp -t dme-entitlements).plist"
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.device.audio-input</key><true/></dict></plist>
PLIST
# A stable identity keeps macOS privacy grants (Full Disk Access, the
# microphone) across rebuilds; an ad-hoc signature changes with every
# build, so macOS sees a new app each time. The identity is a local
# code-signing certificate (Keychain Access > Certificate Assistant >
# Create a Certificate, type Code Signing), named by DME_SIGN_IDENTITY.
identity="${DME_SIGN_IDENTITY:-DME Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$identity\""; then
    codesign --force --sign "$identity" --options runtime --entitlements "$entitlements" "$app"
    echo "signed with: $identity"
else
    codesign --force --sign - --options runtime --entitlements "$entitlements" "$app"
    echo "signed ad hoc (no \"$identity\" certificate): privacy grants will not survive a rebuild"
fi
echo "built: $app"
