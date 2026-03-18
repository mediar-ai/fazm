#!/bin/bash
set -e

# Build configuration
BINARY_NAME="Fazm"  # Package.swift target — binary paths, CFBundleExecutable
APP_NAME="Fazm"
BUNDLE_ID="com.fazm.app"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Verify all DB tables have schema annotations before building
bash scripts/check_schema_docs.sh

# Clean only the release app bundle (preserve other bundles like Fazm Dev.app from run.sh)
rm -rf "$APP_BUNDLE"
mkdir -p "$BUILD_DIR"

# Build acp-bridge
ACP_BRIDGE_DIR="$(dirname "$0")/acp-bridge"
if [ -d "$ACP_BRIDGE_DIR" ]; then
    echo "Building acp-bridge..."
    cd "$ACP_BRIDGE_DIR"
    npm install --no-fund --no-audit
    npm run build --silent
    cd - > /dev/null
fi

# Ensure bundled Node.js exists (for AI chat / ACP Bridge)
NODE_RESOURCE="Desktop/Sources/Resources/node"
if [ -x "$NODE_RESOURCE" ]; then
    echo "Node.js binary already exists, skipping download"
else
    echo "Downloading Node.js binary for dev build..."
    NODE_VERSION="v22.14.0"
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        NODE_ARCH="arm64"
    else
        NODE_ARCH="x64"
    fi
    NODE_TEMP_DIR="/tmp/node-dev-$$"
    mkdir -p "$NODE_TEMP_DIR"
    curl -L -o "$NODE_TEMP_DIR/node.tar.gz" \
        "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
    tar -xzf "$NODE_TEMP_DIR/node.tar.gz" -C "$NODE_TEMP_DIR" --strip-components=1 --include="*/bin/node" 2>/dev/null || \
    tar -xzf "$NODE_TEMP_DIR/node.tar.gz" -C "$NODE_TEMP_DIR"
    NODE_BIN=$(find "$NODE_TEMP_DIR" -name "node" -type f | head -1)
    if [ -n "$NODE_BIN" ]; then
        cp "$NODE_BIN" "$NODE_RESOURCE"
        chmod +x "$NODE_RESOURCE"
        echo "Downloaded Node.js $NODE_VERSION ($NODE_ARCH) to $NODE_RESOURCE"
    else
        echo "Warning: Could not extract Node.js binary. AI chat may not work without system Node.js."
    fi
    rm -rf "$NODE_TEMP_DIR"
fi

# Build release binary
swift build -c release --package-path Desktop

# Get the built binary path
BINARY_PATH=$(swift build -c release --package-path Desktop --show-bin-path)/$BINARY_NAME

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Binary not found at $BINARY_PATH"
    exit 1
fi

echo "Binary built at: $BINARY_PATH"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME"

# Build and bundle mcp-server-macos-use
echo "Building mcp-server-macos-use..."
MCP_REPO="$HOME/mcp-server-macos-use"
if [ -d "$MCP_REPO" ]; then
    swift build -c release --package-path "$MCP_REPO"
    cp "$MCP_REPO/.build/release/mcp-server-macos-use" "$APP_BUNDLE/Contents/MacOS/mcp-server-macos-use"
    echo "Bundled mcp-server-macos-use"
else
    echo "Warning: mcp-server-macos-use not found at $MCP_REPO — skipping"
fi

# Copy Info.plist
cp Desktop/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon
cp fazm_icon.icns "$APP_BUNDLE/Contents/Resources/FazmIcon.icns"

# Update Info.plist with actual values
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $BINARY_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP_BUNDLE/Contents/Info.plist"

# Copy resource bundle (contains app assets like herologo.png, omi-with-rope-no-padding.webp, etc.)
SWIFT_BUILD_DIR=$(swift build -c release --package-path Desktop --show-bin-path)
if [ -d "$SWIFT_BUILD_DIR/Fazm_Fazm.bundle" ]; then
    cp -R "$SWIFT_BUILD_DIR/Fazm_Fazm.bundle" "$APP_BUNDLE/Contents/Resources/"
    echo "Copied resource bundle"
else
    echo "Warning: Resource bundle not found at $SWIFT_BUILD_DIR/Fazm_Fazm.bundle"
fi

# Copy Highlightr resource bundle (required — missing bundle causes fatal crash when rendering code blocks)
HIGHLIGHTR_BUNDLE="$SWIFT_BUILD_DIR/Highlightr_Highlightr.bundle"
if [ -d "$HIGHLIGHTR_BUNDLE" ]; then
    cp -R "$HIGHLIGHTR_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
    echo "Copied Highlightr bundle"
else
    echo "ERROR: Highlightr_Highlightr.bundle not found — build will produce a crashing app"
    exit 1
fi

# Copy acp-bridge
if [ -d "$ACP_BRIDGE_DIR/dist" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/acp-bridge"
    cp -Rf "$ACP_BRIDGE_DIR/dist" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    cp -f "$ACP_BRIDGE_DIR/package.json" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    cp -Rf "$ACP_BRIDGE_DIR/node_modules" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    echo "Copied acp-bridge to bundle"
fi

# Bundle Google Workspace MCP (Python)
GWS_MCP_REPO="$HOME/google_workspace_mcp"
GWS_MCP_BUNDLE="$APP_BUNDLE/Contents/Resources/google-workspace-mcp"
if [ -d "$GWS_MCP_REPO" ]; then
    echo "Bundling Google Workspace MCP..."
    mkdir -p "$GWS_MCP_BUNDLE"
    rsync -a --exclude='.git' --exclude='__pycache__' --exclude='.venv' \
        --exclude='*.pyc' --exclude='.ruff_cache' --exclude='tests' \
        --exclude='docs' --exclude='build' --exclude='dist' --exclude='*.egg-info' \
        "$GWS_MCP_REPO/" "$GWS_MCP_BUNDLE/"
    if command -v uv &>/dev/null; then
        uv venv "$GWS_MCP_BUNDLE/.venv" --python python3.12 --quiet 2>&1 | tail -1 || true
        GWS_DEPS=$(python3.12 -c "
import tomllib
with open('$GWS_MCP_REPO/pyproject.toml', 'rb') as f:
    print(' '.join(tomllib.load(f)['project']['dependencies']))
")
        uv pip install --python "$GWS_MCP_BUNDLE/.venv/bin/python3" $GWS_DEPS --quiet 2>&1 | tail -3 || true
        echo "Bundled Google Workspace MCP with venv"
    else
        echo "Warning: uv not found — Google Workspace MCP will not work without dependencies"
    fi
else
    echo "Warning: Google Workspace MCP not found at $GWS_MCP_REPO — skipping"
fi

# Bundle Hindsight Memory MCP (Python)
HINDSIGHT_BUNDLE="$APP_BUNDLE/Contents/Resources/hindsight"
if command -v uv &>/dev/null; then
    echo "Bundling Hindsight Memory MCP..."
    mkdir -p "$HINDSIGHT_BUNDLE"
    uv venv "$HINDSIGHT_BUNDLE/.venv" --python python3.12 --quiet 2>&1 | tail -1 || true
    uv pip install --python "$HINDSIGHT_BUNDLE/.venv/bin/python3" \
        'hindsight-api-slim[embedded-db]' --quiet 2>&1 | tail -3 || true
    # Remove claude_agent_sdk (195MB) — only needed for claude_code LLM provider, we use anthropic
    uv pip uninstall --python "$HINDSIGHT_BUNDLE/.venv/bin/python3" claude-agent-sdk --quiet 2>/dev/null || true
    echo "Bundled Hindsight Memory MCP with venv"
else
    echo "Warning: uv not found — Hindsight Memory MCP will not be bundled"
fi

# Copy .env.app file (app runtime secrets only)
if [ -f ".env.app" ]; then
    cp ".env.app" "$APP_BUNDLE/Contents/Resources/.env"
    echo "Copied .env.app to bundle"
else
    echo "Warning: No .env.app file found. App may not have required API keys."
fi

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo ""
echo "Build complete: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
echo ""
echo "Or copy to Applications:"
echo "  cp -r $APP_BUNDLE /Applications/"
