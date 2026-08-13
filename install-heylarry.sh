#!/bin/bash
# Install the newest Hey Larry build straight from GitHub — no browser needed.
#
# Actions artifacts require an authenticated download even on a public repo,
# which is why every test build used to be fetched by hand. The workflow also
# publishes each build as a rolling prerelease, and release assets on a public
# repo are open, so this URL can just be curled.
set -euo pipefail

URL="https://github.com/Victoractivepromotion/Hex/releases/download/heylarry-latest/Hex.dmg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [ -n "${MOUNT:-}" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT

echo "→ downloading newest build"
curl -fsSL --retry 3 -o "$WORK/Hex.dmg" "$URL"
echo "  $(du -h "$WORK/Hex.dmg" | cut -f1)"

echo "→ quitting Hex"
killall Hex 2>/dev/null || true
sleep 1

echo "→ mounting"
MOUNT="$(hdiutil attach -nobrowse -readonly "$WORK/Hex.dmg" | grep -o '/Volumes/.*' | tail -1)"
[ -d "$MOUNT/Hex.app" ] || { echo "!! no Hex.app inside the DMG"; exit 1; }

# Keep exactly one Hex in /Applications: macOS binds Accessibility and Input
# Monitoring per app, and duplicate "Hex" rows in those lists are impossible to
# tell apart — toggling the wrong one silently leaves the real app unpermitted.
echo "→ installing to /Applications/Hex.app"
rm -rf /Applications/Hex.app
ditto "$MOUNT/Hex.app" /Applications/Hex.app

# Unsigned build: without this macOS refuses to open it at all.
xattr -cr /Applications/Hex.app

# The Active Agent button's quit sentinel would otherwise keep it closed.
rm -f "$HOME/.claude/bg/hex-quit" "$HOME/.claude/bg/hex-seen"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Hex.app

echo "→ launching"
open /Applications/Hex.app
sleep 5

echo
echo "installed build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Hex.app/Contents/Info.plist)"
pgrep -f "MacOS/Hex" >/dev/null && echo "Hex is running." || echo "!! Hex did not start"
