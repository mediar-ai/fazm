#!/bin/bash
set -e

# Clear system OPENAI_API_KEY so .env takes precedence
unset OPENAI_API_KEY

# Use Xcode's default toolchain to match the SDK version
unset TOOLCHAINS

# Timing utilities
SCRIPT_START_TIME=$(date +%s.%N)
STEP_START_TIME=$SCRIPT_START_TIME

step() {
    local now=$(date +%s.%N)
    local step_elapsed=$(echo "$now - $STEP_START_TIME" | bc)
    local total_elapsed=$(echo "$now - $SCRIPT_START_TIME" | bc)
    if [ "$STEP_START_TIME" != "$SCRIPT_START_TIME" ]; then
        printf "  └─ done (%.2fs)\n" "$step_elapsed"
    fi
    STEP_START_TIME=$now
    printf "[%6.1fs] %s\n" "$total_elapsed" "$1"
}

substep() {
    local now=$(date +%s.%N)
    local total_elapsed=$(echo "$now - $SCRIPT_START_TIME" | bc)
    printf "[%6.1fs]   ├─ %s\n" "$total_elapsed" "$1"
}

# App configuration
BINARY_NAME="Fazm"  # Package.swift target — binary paths, pkill, CFBundleExecutable
APP_NAME="Fazm Dev"
BUNDLE_ID="com.fazm.desktop-dev"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_PATH="/Applications/$APP_NAME.app"
SIGN_IDENTITY="${FAZM_SIGN_IDENTITY:-}"

AUTH_DEBUG_LOG=/private/tmp/auth-debug.log
rm -f $AUTH_DEBUG_LOG
auth_debug() { echo "[AUTH DEBUG][$(date +%H:%M:%S)] $1" >> $AUTH_DEBUG_LOG; }
touch $AUTH_DEBUG_LOG

step "Killing existing instances..."
auth_debug "BEFORE pkill: auth_isSignedIn=$(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"
auth_debug "BEFORE pkill: ALL_KEYS=$(defaults read "$BUNDLE_ID" 2>&1 | grep -E 'auth_|hasCompleted|hasLaunched|currentTier|userShow' || true)"
# Only kill the dev app — never touch Fazm (production)
pkill -f "$APP_NAME.app" 2>/dev/null || true
sleep 0.5  # Let cfprefsd flush after process death

# Remove crash-detection flag files so the dev relaunch isn't treated as a crash
find ~/Library/Application\ Support/Fazm/users -name ".fazm_running" -delete 2>/dev/null || true
auth_debug "AFTER pkill: auth_isSignedIn=$(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"
auth_debug "AFTER pkill: ALL_KEYS=$(defaults read "$BUNDLE_ID" 2>&1 | grep -E 'auth_|hasCompleted|hasLaunched|currentTier|userShow' || true)"

# Clear log file for fresh run (must be before backend starts)
rm -f /tmp/fazm-dev.log 2>/dev/null || true

step "Cleaning up conflicting app bundles..."
# Clean old build names from local build dir
rm -rf "$BUILD_DIR/Omi Computer.app" "$BUILD_DIR/Omi Dev.app" 2>/dev/null
CONFLICTING_APPS=(
    "/Applications/Omi Computer.app"
    "/Applications/Omi.app"
    "/Applications/Omi Dev.app"
    "/Applications/Omi Beta.app"
    "$HOME/Desktop/Fazm.app"
    "$HOME/Desktop/Fazm Dev.app"
    "$HOME/Downloads/Fazm.app"
    "$HOME/Downloads/Fazm Dev.app"
)
for app in "${CONFLICTING_APPS[@]}"; do
    if [ -d "$app" ]; then
        substep "Removing: $app"
        rm -rf "$app"
    fi
done
# Remove stale "Fazm Dev.app" from known worktree/clone locations
for stale_dir in "$HOME"/fazm-*/build "$HOME"/*/fazm/build "$HOME"/fazm/.claude/worktrees/*/build; do
    stale="$stale_dir/Fazm Dev.app"
    if [ -d "$stale" ] && [ "$stale" != "$APP_BUNDLE" ]; then
        substep "Removing stale clone: $stale"
        rm -rf "$stale"
    fi
done

# Check if another SwiftPM instance is running (will block our build)
SWIFTPM_PID=$(pgrep -f "swiftpm-workspace-state|swift-build|swift-package" 2>/dev/null | head -1)
if [ -n "$SWIFTPM_PID" ]; then
    step "Waiting for other SwiftPM instance (PID: $SWIFTPM_PID) to finish..."
    while kill -0 "$SWIFTPM_PID" 2>/dev/null; do
        sleep 1
    done
fi

step "Building acp-bridge (npm install + tsc)..."
ACP_BRIDGE_DIR="$(dirname "$0")/acp-bridge"
if [ -d "$ACP_BRIDGE_DIR" ]; then
    cd "$ACP_BRIDGE_DIR"
    if [ ! -d "node_modules" ] || [ "package.json" -nt "node_modules/.package-lock.json" ]; then
        substep "Installing npm dependencies"
        npm install --no-fund --no-audit 2>&1 | tail -1
    fi
    substep "Compiling TypeScript and copying assets"
    npm run build --silent
    cd - > /dev/null
else
    echo "Warning: acp-bridge directory not found at $ACP_BRIDGE_DIR"
fi

step "Ensuring ffmpeg binary..."
FFMPEG_RESOURCE="Desktop/Sources/Resources/ffmpeg"
if [ -x "$FFMPEG_RESOURCE" ]; then
    substep "ffmpeg binary already present"
else
    substep "Downloading ffmpeg for dev build..."
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        FFMPEG_ARCH="arm64"
    else
        FFMPEG_ARCH="amd64"
    fi
    FFMPEG_TEMP="/tmp/ffmpeg-dev-$$"
    mkdir -p "$FFMPEG_TEMP"
    curl -L -o "$FFMPEG_TEMP/ffmpeg.zip" \
        "https://ffmpeg.martin-riedl.de/redirect/latest/macos/$FFMPEG_ARCH/release/ffmpeg.zip"
    unzip -q -o "$FFMPEG_TEMP/ffmpeg.zip" -d "$FFMPEG_TEMP/"
    FFMPEG_BIN=$(find "$FFMPEG_TEMP" -name "ffmpeg" -type f | head -1)
    cp "$FFMPEG_BIN" "$FFMPEG_RESOURCE"
    chmod +x "$FFMPEG_RESOURCE"
    codesign -f -s - "$FFMPEG_RESOURCE"
    rm -rf "$FFMPEG_TEMP"
    substep "Downloaded ffmpeg to $FFMPEG_RESOURCE"
fi

step "Checking schema docs..."
bash scripts/check_schema_docs.sh

step "Building Swift app (swift build -c debug)..."
xcrun swift build -c debug --package-path Desktop

auth_debug "AFTER swift build: auth_isSignedIn=$(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"

step "Creating app bundle..."
substep "Creating directories"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

substep "Copying binary ($(du -h "Desktop/.build/debug/$BINARY_NAME" 2>/dev/null | cut -f1))"
cp -f "Desktop/.build/debug/$BINARY_NAME" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

# Build and bundle mcp-server-macos-use
MCP_REPO="$HOME/mcp-server-macos-use"
if [ -d "$MCP_REPO" ]; then
    substep "Building mcp-server-macos-use..."
    xcrun swift build -c debug --package-path "$MCP_REPO"
    cp -f "$MCP_REPO/.build/debug/mcp-server-macos-use" "$APP_BUNDLE/Contents/MacOS/mcp-server-macos-use"
    substep "Bundled mcp-server-macos-use ($(du -h "$APP_BUNDLE/Contents/MacOS/mcp-server-macos-use" | cut -f1))"
else
    echo "Warning: mcp-server-macos-use not found at $MCP_REPO — skipping"
fi

# Build and bundle whatsapp-mcp
MCP_WHATSAPP="$HOME/whatsapp-mcp-skill-macos"
if [ -d "$MCP_WHATSAPP" ]; then
    substep "Building whatsapp-mcp..."
    xcrun swift build -c debug --package-path "$MCP_WHATSAPP"
    cp -f "$MCP_WHATSAPP/.build/debug/whatsapp-mcp" "$APP_BUNDLE/Contents/MacOS/whatsapp-mcp"
    substep "Bundled whatsapp-mcp ($(du -h "$APP_BUNDLE/Contents/MacOS/whatsapp-mcp" | cut -f1))"
else
    echo "Warning: whatsapp-mcp not found at $MCP_WHATSAPP — skipping"
fi

substep "Adding rpath for Frameworks"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true

# Copy Sparkle framework
SPARKLE_FRAMEWORK="Desktop/.build/arm64-apple-macosx/debug/Sparkle.framework"
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    substep "Copying Sparkle framework ($(du -sh "$SPARKLE_FRAMEWORK" 2>/dev/null | cut -f1))"
    rm -rf "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
fi

substep "Copying Info.plist"
cp -f Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BINARY_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 fazm-dev" "$APP_BUNDLE/Contents/Info.plist"

auth_debug "AFTER plist edits: auth_isSignedIn=$(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"

# Copy resource bundle (contains app assets like permissions.gif, herologo.png, etc.)
RESOURCE_BUNDLE="Desktop/.build/arm64-apple-macosx/debug/Fazm_Fazm.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    substep "Copying resource bundle ($(du -sh "$RESOURCE_BUNDLE" 2>/dev/null | cut -f1))"
    cp -Rf "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# Copy Highlightr resource bundle (required — missing bundle causes fatal crash when rendering code blocks)
HIGHLIGHTR_BUNDLE="Desktop/.build/arm64-apple-macosx/debug/Highlightr_Highlightr.bundle"
if [ -d "$HIGHLIGHTR_BUNDLE" ]; then
    substep "Copying Highlightr bundle"
    cp -Rf "$HIGHLIGHTR_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

substep "Copying acp-bridge"
if [ -d "$ACP_BRIDGE_DIR/dist" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/acp-bridge"
    cp -Rf "$ACP_BRIDGE_DIR/dist" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    cp -f "$ACP_BRIDGE_DIR/package.json" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    cp -Rf "$ACP_BRIDGE_DIR/node_modules" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    # Copy Vertex AI service account key if present (for Hindsight MCP)
    if [ -f "$ACP_BRIDGE_DIR/vertex-ai-sa-key.json" ]; then
        cp -f "$ACP_BRIDGE_DIR/vertex-ai-sa-key.json" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    fi
fi

# Bundle Google Workspace MCP (Python)
WORKSPACE_MCP_REPO="$HOME/google_workspace_mcp"
WORKSPACE_MCP_BUNDLE="$APP_BUNDLE/Contents/Resources/google-workspace-mcp"
if [ -d "$WORKSPACE_MCP_REPO" ]; then
    substep "Bundling Google Workspace MCP"
    mkdir -p "$WORKSPACE_MCP_BUNDLE"
    # Copy source (excluding dev artifacts)
    rsync -a --exclude='.git' --exclude='__pycache__' --exclude='.venv' \
        --exclude='*.pyc' --exclude='.ruff_cache' --exclude='tests' \
        --exclude='docs' --exclude='build' --exclude='dist' --exclude='*.egg-info' \
        "$WORKSPACE_MCP_REPO/" "$WORKSPACE_MCP_BUNDLE/"
    # Create venv and install dependencies using uv
    if command -v uv &>/dev/null; then
        substep "Creating Python venv with uv"
        uv venv "$WORKSPACE_MCP_BUNDLE/.venv" --python python3.12 --quiet 2>&1 | tail -1 || true
        # Install dependencies (extracted from pyproject.toml) into the bundled venv
        WORKSPACE_MCP_DEPS=$(python3.12 -c "
import tomllib
with open('$WORKSPACE_MCP_REPO/pyproject.toml', 'rb') as f:
    print(' '.join(tomllib.load(f)['project']['dependencies']))
")
        uv pip install --python "$WORKSPACE_MCP_BUNDLE/.venv/bin/python3" $WORKSPACE_MCP_DEPS --quiet 2>&1 | tail -3 || true
        substep "Bundled Google Workspace MCP with venv"
    else
        substep "Warning: uv not found — Google Workspace MCP will not work without dependencies"
    fi
else
    echo "Warning: Google Workspace MCP not found at $WORKSPACE_MCP_REPO — skipping"
fi

# Bundle Hindsight Memory MCP (Python)
HINDSIGHT_BUNDLE="$APP_BUNDLE/Contents/Resources/hindsight"
if command -v uv &>/dev/null; then
    substep "Bundling Hindsight Memory MCP"
    mkdir -p "$HINDSIGHT_BUNDLE"
    if [ ! -d "$HINDSIGHT_BUNDLE/.venv" ]; then
        uv venv "$HINDSIGHT_BUNDLE/.venv" --python python3.12 --quiet 2>&1 | tail -1 || true
        uv pip install --python "$HINDSIGHT_BUNDLE/.venv/bin/python3" \
            'hindsight-api-slim[embedded-db]' sentence-transformers --quiet 2>&1 | tail -3 || true
        # Remove claude_agent_sdk (195MB) — only needed for claude_code LLM provider
        uv pip uninstall --python "$HINDSIGHT_BUNDLE/.venv/bin/python3" claude-agent-sdk --quiet 2>/dev/null || true
        substep "Bundled Hindsight Memory MCP with venv"
    else
        substep "Hindsight venv already exists, skipping install"
    fi
else
    echo "Warning: uv not found — Hindsight Memory MCP will not be bundled"
fi

substep "Copying .env.app"
if [ -f ".env.app.dev" ]; then
    cp -f .env.app.dev "$APP_BUNDLE/Contents/Resources/.env"
elif [ -f ".env.app" ]; then
    cp -f .env.app "$APP_BUNDLE/Contents/Resources/.env"
else
    touch "$APP_BUNDLE/Contents/Resources/.env"
fi

substep "Copying app icon"
cp -f fazm_icon.icns "$APP_BUNDLE/Contents/Resources/FazmIcon.icns" 2>/dev/null || true

substep "Creating PkgInfo"
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

auth_debug "BEFORE signing: $(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"

step "Removing extended attributes (xattr -cr)..."
xattr -cr "$APP_BUNDLE"

step "Signing app with hardened runtime..."
# Auto-detect a stable signing identity so TCC permissions persist across rebuilds.
# Ad-hoc signing (--sign -) generates a new CDHash each build, causing macOS to
# reset Screen Recording, Accessibility, and Notification permissions every time.
if [ -z "$SIGN_IDENTITY" ]; then
    # For dev builds: prefer Apple Development (matches Mac Development provisioning profile,
    # required for native Sign In with Apple). Fall back to Developer ID if unavailable.
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
    if [ -z "$SIGN_IDENTITY" ]; then
        SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
    fi
fi

if [ -n "$SIGN_IDENTITY" ]; then
    substep "Using identity: $SIGN_IDENTITY"
    if [ -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
        substep "Signing Sparkle framework"
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    fi
    # Sign the bundled ffmpeg binary
    FFMPEG_BIN="$APP_BUNDLE/Contents/Resources/Fazm_Fazm.bundle/ffmpeg"
    if [ -f "$FFMPEG_BIN" ]; then
        substep "Signing bundled ffmpeg binary"
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$FFMPEG_BIN"
    fi
    # Sign the bundled node binary with developer identity + Node.entitlements
    # (macOS requires executables inside app bundles to be properly signed)
    NODE_BIN="$APP_BUNDLE/Contents/Resources/Fazm_Fazm.bundle/node"
    if [ -f "$NODE_BIN" ]; then
        substep "Signing bundled node binary"
        codesign --force --options runtime --entitlements Desktop/Node.entitlements --sign "$SIGN_IDENTITY" "$NODE_BIN"
    fi
    MCP_BIN="$APP_BUNDLE/Contents/MacOS/mcp-server-macos-use"
    if [ -f "$MCP_BIN" ]; then
        substep "Signing mcp-server-macos-use"
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$MCP_BIN"
    fi
    WHATSAPP_BIN="$APP_BUNDLE/Contents/MacOS/whatsapp-mcp"
    if [ -f "$WHATSAPP_BIN" ]; then
        substep "Signing whatsapp-mcp"
        codesign --force --options runtime --sign "$SIGN_IDENTITY" "$WHATSAPP_BIN"
    fi
    substep "Signing app bundle"
    codesign --force --options runtime --entitlements Desktop/Fazm.entitlements --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
else
    substep "Warning: No signing identity found. Using ad-hoc (permissions will reset each build)."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

step "Removing quarantine attributes..."
xattr -cr "$APP_BUNDLE"

step "Installing to /Applications/..."
# Install to /Applications/ so "Quit & Reopen" (after granting screen recording
# permission) launches the correct binary instead of a stale copy elsewhere.
ditto "$APP_BUNDLE" "$APP_PATH"
substep "Installed to $APP_PATH"

step "Clearing stale LaunchServices registration..."
# Unregister first to clear any launch-disabled flag from stale entries,
# then let `open` re-register the app fresh. Without this, notifications
# fail with "Notifications are not allowed for this application" because
# the launch-disabled flag prevents notification center registration.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
$LSREGISTER -u "$APP_BUNDLE" 2>/dev/null || true
$LSREGISTER -u "$APP_PATH" 2>/dev/null || true
# Purge stale registrations from old DMG staging dirs and unmounted volumes
# These create ghost entries that can cause notification icons to show a
# generic folder instead of the app icon
for stale in /private/tmp/fazm-dmg-staging-*/Fazm.app; do
    [ -d "$stale" ] || $LSREGISTER -u "$stale" 2>/dev/null || true
done
# Register the /Applications/ copy as the canonical bundle for this bundle ID
$LSREGISTER -f "$APP_PATH" 2>/dev/null || true

# Force Dock icon update via NSWorkspace.setIcon (writes resource fork onto .app bundle).
# This breaks code signing but is fine for dev builds. Without this, macOS caches the old
# Dock icon indefinitely even after lsregister reset + iconservicesagent kill.
python3 -c "
import AppKit
icon = AppKit.NSImage.alloc().initWithContentsOfFile_('$(pwd)/fazm_icon.icns')
if icon:
    AppKit.NSWorkspace.sharedWorkspace().setIcon_forFile_options_(icon, '$APP_PATH', 0)
" 2>/dev/null || true

step "Starting app..."

# Print summary
NOW=$(date +%s.%N)
TOTAL_TIME=$(echo "$NOW - $SCRIPT_START_TIME" | bc)
printf "  └─ done (%.2fs)\n" "$(echo "$NOW - $STEP_START_TIME" | bc)"
echo ""
echo "=== App Running (total: ${TOTAL_TIME%.*}s) ==="
echo "App:      $APP_PATH (installed from $APP_BUNDLE)"
echo "========================================"
echo ""

auth_debug "BEFORE launch: $(defaults read "$BUNDLE_ID" auth_isSignedIn 2>&1 || true)"
open "$APP_PATH" || "$APP_PATH/Contents/MacOS/$BINARY_NAME" &

# Keep script running so Ctrl+C can be used to stop
echo "Press Ctrl+C to stop..."
wait
