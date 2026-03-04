#!/bin/bash
set -e

###############################################################################
# RESET AND RUN SCRIPT FOR FAZM DESKTOP DEVELOPMENT
###############################################################################
#
# This script builds and runs the Fazm Desktop app with a clean slate for testing.
# It handles permission resets, app cleanup, and backend services.
#
# CRITICAL: ORDER OF OPERATIONS MATTERS!
# =============================================================================
# The sequence below was determined through extensive debugging. DO NOT change
# the order without understanding why it matters.
#
# CORRECT ORDER:
#   1. Kill app processes
#   2. Reset TCC permissions (while app STILL EXISTS in /Applications)
#   3. Delete app bundles
#   4. Reset Launch Services
#   5. Build new app
#   6. Install to /Applications
#   7. Reset UserDefaults
#   8. Launch app
#
# WHY THIS ORDER MATTERS:
# -----------------------
# - tccutil reset requires the app to exist to properly resolve the bundle ID.
#   If you delete the app first, tccutil silently fails to reset permissions.
#   This was discovered after hours of debugging where permissions appeared
#   "stuck" even after running tccutil.
#
# - The app must be killed BEFORE resetting TCC, otherwise the running app
#   may re-acquire permissions immediately.
#
# MACOS TCC (TRANSPARENCY, CONSENT, CONTROL) NOTES:
# =============================================================================
# - User TCC database: ~/Library/Application Support/com.apple.TCC/TCC.db
#   Contains: Microphone, AudioCapture, AppleEvents, Accessibility
#   Can be modified with: tccutil reset, sqlite3 DELETE
#
# - System TCC database: /Library/Application Support/com.apple.TCC/TCC.db
#   Contains: ScreenCapture (Screen Recording)
#   PROTECTED BY SIP - cannot be modified directly, even with sudo
#   Can only be reset via: tccutil reset ScreenCapture <bundle-id>
#   Or manually removed in: System Settings > Privacy & Security > Screen Recording
#
# - CGPreflightScreenCaptureAccess() can return STALE data after app rebuilds.
#   It may say "true" when the permission is actually invalid for the new binary.
#
# - ScreenCaptureKit (macOS 14+) has its OWN consent separate from TCC.
#   SCShareableContent.excludingDesktopWindows() triggers this consent dialog.
#   Don't call it repeatedly - it will show the dialog each time if not granted.
#
# LAUNCH SERVICES POLLUTION:
# =============================================================================
# Launch Services caches app metadata (bundle ID, name, icon) from ALL apps it
# sees, including:
#   - DMG staging directories in /private/tmp
#   - Mounted DMG volumes (/Volumes/Fazm, /Volumes/dmg.*)
#   - Apps in Trash
#   - Xcode DerivedData builds
#
# If multiple apps with the same bundle ID exist (even in Trash!), macOS gets
# confused and may:
#   - Show wrong app name in System Settings (e.g., "Fazm.app" with .app)
#   - Show generic icon instead of actual app icon
#   - Grant permissions to the wrong app
#
# SOLUTION: Clean up ALL these locations before building:
#   - /private/tmp/fazm-dmg-staging-*
#   - ~/.Trash/Fazm*, ~/.Trash/Omi*
#   - Mounted volumes: /Volumes/Fazm*, /Volumes/dmg.*
#   - Xcode DerivedData Fazm builds
#
# The lsregister -kill command is supposed to rebuild the database but is
# disabled on modern macOS. A reboot may be needed for complete cleanup.
#
# DEBUGGING TIPS:
# =============================================================================
# Check TCC entries:
#   sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
#     "SELECT service, client, auth_value FROM access WHERE client LIKE '%fazm%';"
#
# Check Launch Services registrations:
#   lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
#   $lsregister -dump | grep -A20 "com.fazm.app"
#
# Check screen recording permission:
#   swift -e 'import CoreGraphics; print(CGPreflightScreenCaptureAccess())'
#
# Manually reset all TCC for a bundle:
#   tccutil reset All com.fazm.desktop-dev
#
###############################################################################

# Clear system OPENAI_API_KEY so .env takes precedence
unset OPENAI_API_KEY

# Use Xcode's default toolchain to match the SDK version
unset TOOLCHAINS

# App configuration
BINARY_NAME="Fazm"  # Package.swift target — binary paths, pkill, CFBundleExecutable
APP_NAME="Fazm Dev"
BUNDLE_ID="com.fazm.desktop-dev"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_PATH="/Applications/$APP_NAME.app"
# Auto-detect signing identity: prefer Apple Development (doesn't require notarization),
# fall back to Developer ID Application
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
fi
if [ -z "$SIGN_IDENTITY" ]; then
    echo "ERROR: No signing identity found"
    exit 1
fi

# Kill existing instances
echo "Killing existing instances..."
pkill -f "$APP_NAME.app" 2>/dev/null || true

# Clear log file for fresh run (must be before backend starts)
rm -f /tmp/fazm.log 2>/dev/null || true

# =============================================================================
# STEP 2: RESET TCC PERMISSIONS
# =============================================================================
# CRITICAL: This MUST happen BEFORE deleting the app from /Applications!
# tccutil needs the app to exist to resolve the bundle ID and find the correct
# TCC entries to reset. If the app doesn't exist, tccutil silently succeeds
# but doesn't actually reset anything.
#
# We reset BOTH bundle IDs:
# - Development: com.fazm.desktop-dev (this script's builds)
# - Production: com.fazm.app (release DMG builds)
#
# Using "reset All" instead of individual services (ScreenCapture, Microphone, etc.)
# because it's more reliable and catches any permissions we might have missed.
BUNDLE_ID_PROD="com.fazm.app"
echo "Resetting TCC permissions (before deleting apps)..."
tccutil reset All "$BUNDLE_ID" 2>/dev/null || true
tccutil reset All "$BUNDLE_ID_PROD" 2>/dev/null || true

# Belt-and-suspenders: Also clean user TCC database directly via sqlite3
# This catches any entries that tccutil might have missed
# Note: System TCC database (Screen Recording) is SIP-protected and cannot be
# modified this way - only tccutil can reset it
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "DELETE FROM access WHERE client LIKE '%com.fazm.app%' OR client LIKE '%com.omi.computer-macos%';" 2>/dev/null || true
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "DELETE FROM access WHERE client LIKE '%com.fazm.desktop%' OR client LIKE '%com.omi.desktop%';" 2>/dev/null || true

# =============================================================================
# STEP 3: DELETE ALL CONFLICTING APP BUNDLES
# =============================================================================
# Multiple apps with the same bundle ID confuse macOS. When granting permissions,
# the system may pick the wrong app, resulting in:
# - Permissions granted to old/deleted app instead of new build
# - Wrong app name/icon shown in System Settings
# - "Quit and reopen" prompt not appearing after enabling permissions
#
# We clean up apps from ALL possible locations where they might exist.
echo "Cleaning up conflicting app bundles..."
CONFLICTING_APPS=(
    "/Applications/Fazm.app"
    "/Applications/Fazm Dev.app"
    "/Applications/Omi.app"
    "/Applications/Omi Computer.app"
    "/Applications/Omi Dev.app"
    "/Applications/Omi Beta.app"
    "$APP_BUNDLE"  # Local build folder
    "$HOME/Desktop/Fazm.app"
    "$HOME/Downloads/Fazm.app"
)
# Kill stale "Fazm Dev.app" bundles from other repo clones
# These confuse LaunchServices and get launched instead of /Applications/Fazm Dev.app
echo "Scanning for stale Fazm Dev.app in other locations..."
find "$HOME" -maxdepth 4 -name "Fazm Dev.app" -type d -not -path "$APP_BUNDLE" -not -path "$APP_PATH" 2>/dev/null | while read stale; do
    echo "  Removing stale clone: $stale"
    rm -rf "$stale"
done
# Xcode DerivedData can contain old builds with production bundle ID
# These get registered in Launch Services and cause permission confusion
echo "Cleaning Xcode DerivedData..."
find "$HOME/Library/Developer/Xcode/DerivedData" -name "Fazm.app" -o -name "Fazm Dev.app" -o -name "Omi.app" -o -name "Omi Computer.app" -type d 2>/dev/null | while read app; do
    echo "  Removing: $app"
    rm -rf "$app"
done

# DMG staging directories from release.sh builds contain production bundle ID apps
# Launch Services sees these and caches them, causing permission confusion
echo "Cleaning DMG staging directories..."
rm -rf /private/tmp/fazm-dmg-staging-* /private/tmp/fazm-dmg-test-* /private/tmp/omi-dmg-staging-* /private/tmp/omi-dmg-test-* 2>/dev/null || true

# IMPORTANT: Apps in Trash are STILL registered in Launch Services!
# This was a major source of bugs - deleted apps in Trash were being picked up
# by macOS when granting permissions, resulting in wrong app names/icons
echo "Cleaning Fazm/Omi apps from Trash..."
rm -rf "$HOME/.Trash/Fazm"* "$HOME/.Trash/OMI"* "$HOME/.Trash/Omi"* 2>/dev/null || true

# Mounted DMG volumes also register their apps in Launch Services
# If you opened a release DMG to test, the mounted app pollutes the database
echo "Ejecting mounted Fazm/Omi DMG volumes..."
for vol in /Volumes/Fazm* /Volumes/Omi* /Volumes/OMI* /Volumes/dmg.*; do
    if [ -d "$vol" ]; then
        echo "  Ejecting: $vol"
        diskutil eject "$vol" 2>/dev/null || hdiutil detach "$vol" 2>/dev/null || true
    fi
done

for app in "${CONFLICTING_APPS[@]}"; do
    if [ -d "$app" ]; then
        echo "  Removing: $app"
        rm -rf "$app"
    fi
done

# =============================================================================
# STEP 4: RESET LAUNCH SERVICES DATABASE
# =============================================================================
# Launch Services caches app metadata (bundle ID → app path, name, icon).
# After cleaning up old apps, we need to tell Launch Services to rebuild.
#
# NOTE: The -kill flag is deprecated/disabled on modern macOS. This command
# may not fully clear the cache. If you still see wrong app names/icons in
# System Settings after running this script, a REBOOT may be required to
# fully rebuild the Launch Services database.
#
# The lsregister tool reads from an in-memory daemon, not disk. Deleting the
# database file (~/.../com.apple.LaunchServices.lsdb) only takes effect after
# the daemon restarts (i.e., after reboot).
echo "Resetting Launch Services database..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain user 2>/dev/null || true

# Build acp-bridge
echo "Building acp-bridge..."
ACP_BRIDGE_DIR="$(dirname "$0")/acp-bridge"
if [ -d "$ACP_BRIDGE_DIR" ]; then
    cd "$ACP_BRIDGE_DIR"
    if [ ! -d "node_modules" ] || [ "package.json" -nt "node_modules/.package-lock.json" ]; then
        npm install --no-fund --no-audit 2>&1 | tail -1
    fi
    npx tsc
    cd - > /dev/null
fi

# Build debug
echo "Building app..."
xcrun swift build -c debug --package-path Desktop

# Remove old app bundles to avoid permission issues with signed apps
rm -rf "$APP_BUNDLE" "$BUILD_DIR/Omi Computer.app" "$BUILD_DIR/Omi Dev.app"

# Create app bundle
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "Desktop/.build/debug/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

# Add rpath for Frameworks folder (needed for Sparkle)
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true

# Copy Sparkle framework (keep original signatures intact)
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
SPARKLE_FRAMEWORK="Desktop/.build/arm64-apple-macosx/debug/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
    echo "  Copied Sparkle.framework"
fi

# Copy resource bundle (contains app assets like permissions.gif, herologo.png, etc.)
RESOURCE_BUNDLE="Desktop/.build/arm64-apple-macosx/debug/Fazm_Fazm.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -Rf "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo "  Copied resource bundle"
fi

# Copy acp-bridge
if [ -d "$ACP_BRIDGE_DIR/dist" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/acp-bridge"
    cp -Rf "$ACP_BRIDGE_DIR/dist" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    cp -f "$ACP_BRIDGE_DIR/package.json" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    cp -Rf "$ACP_BRIDGE_DIR/node_modules" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    echo "  Copied acp-bridge to bundle"
fi

# Copy and fix Info.plist
cp Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BINARY_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 fazm-dev" "$APP_BUNDLE/Contents/Info.plist"

# Copy .env.app (app runtime secrets only)
if [ -f ".env.app" ]; then
    cp .env.app "$APP_BUNDLE/Contents/Resources/.env"
else
    touch "$APP_BUNDLE/Contents/Resources/.env"
fi

# Copy app icon
cp fazm_icon.icns "$APP_BUNDLE/Contents/Resources/FazmIcon.icns" 2>/dev/null || true

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Strip extended attributes before signing (prevents "resource fork, Finder information" errors)
xattr -cr "$APP_BUNDLE"

# Sign Sparkle framework components individually (like release.sh does)
echo "Signing Sparkle framework components..."
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    # Sign innermost components first
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/Autoupdate" 2>/dev/null || true
    codesign --force --options runtime --sign "$SIGN_IDENTITY" \
        "$SPARKLE_FW/Versions/B/Updater.app" 2>/dev/null || true
    # Sign framework itself
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
fi

# Sign main app
echo "Signing app..."
codesign --force --options runtime --entitlements Desktop/Fazm.entitlements --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

# Install to /Applications
echo "Installing to /Applications..."
rm -rf "$APP_PATH"
ditto "$APP_BUNDLE" "$APP_PATH"

# Reset app data (UserDefaults, onboarding state, etc.) for BOTH bundle IDs
# (TCC permissions were already reset before building)
echo "Resetting app data..."
defaults delete "$BUNDLE_ID" 2>/dev/null || true
defaults delete "$BUNDLE_ID_PROD" 2>/dev/null || true

# Clear delivered notifications
echo "Clearing notifications..."
osascript -e "tell application \"System Events\" to tell process \"NotificationCenter\" to click button 1 of every window" 2>/dev/null || true

# Note: Notification PERMISSIONS cannot be reset programmatically (Apple limitation)
# To fully reset notification permissions, manually go to:
# System Settings > Notifications > Fazm > Remove
echo "Note: Notification permissions can only be reset manually in System Settings"

echo ""
echo "=== App Running ==="
echo "App:      $APP_PATH"
echo "==================="
echo ""

# Re-register with LaunchServices (clear stale launch-disabled flags)
echo "Re-registering with LaunchServices..."
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
$LSREGISTER -u "$APP_PATH" 2>/dev/null || true
$LSREGISTER -f "$APP_PATH" 2>/dev/null || true

# Remove quarantine and start app from /Applications
echo "Starting app..."
xattr -cr "$APP_PATH"
open "$APP_PATH" || "$APP_PATH/Contents/MacOS/$BINARY_NAME" &

# Keep script running so Ctrl+C can be used to stop
echo "Press Ctrl+C to stop..."
wait
