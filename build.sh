#!/bin/bash
set -e

# Acquire exclusive lock — prevents concurrent builds/tests by parallel agents
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/scripts/fazm-lock.sh"
fazm_acquire_lock 300

# Build configuration
BINARY_NAME="Fazm"  # Package.swift target — binary paths, CFBundleExecutable
APP_NAME="Fazm"
BUNDLE_ID="com.fazm.app"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Use Xcode's default toolchain to match the SDK version
unset TOOLCHAINS

echo "Building $APP_NAME..."

# Verify all DB tables have schema annotations before building
bash scripts/check_schema_docs.sh

# Verify all settings UI elements have search entries
bash scripts/check_search_coverage.sh

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

# Ensure bundled cloudflared exists (for WebRelay tunnel)
CLOUDFLARED_RESOURCE="Desktop/Sources/Resources/cloudflared"
if [ -x "$CLOUDFLARED_RESOURCE" ]; then
    echo "cloudflared binary already exists, skipping download"
else
    echo "Downloading cloudflared binary for build..."
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        CF_ARCH="arm64"
    else
        CF_ARCH="amd64"
    fi
    CF_TEMP_DIR="/tmp/cloudflared-$$"
    mkdir -p "$CF_TEMP_DIR"
    curl -L -o "$CF_TEMP_DIR/cloudflared.tgz" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-$CF_ARCH.tgz"
    tar -xzf "$CF_TEMP_DIR/cloudflared.tgz" -C "$CF_TEMP_DIR"
    cp "$CF_TEMP_DIR/cloudflared" "$CLOUDFLARED_RESOURCE"
    chmod +x "$CLOUDFLARED_RESOURCE"
    echo "Downloaded cloudflared ($CF_ARCH) to $CLOUDFLARED_RESOURCE"
    rm -rf "$CF_TEMP_DIR"
fi

# Build release binary
xcrun swift build -c release --package-path Desktop

# Get the built binary path
BINARY_PATH=$(xcrun swift build -c release --package-path Desktop --show-bin-path)/$BINARY_NAME

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

# Add rpath for Frameworks
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$BINARY_NAME" 2>/dev/null || true

# Copy Sparkle framework
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
SPARKLE_FRAMEWORK="Desktop/.build/arm64-apple-macosx/release/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    SPARKLE_FRAMEWORK="Desktop/.build/x86_64-apple-macosx/release/Sparkle.framework"
fi
if [ -d "$SPARKLE_FRAMEWORK" ]; then
    ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    echo "Copied Sparkle framework"
else
    echo "ERROR: Sparkle.framework not found — app will crash at launch"
    exit 1
fi

# Build and bundle mcp-server-macos-use
echo "Building mcp-server-macos-use..."
MCP_REPO="$HOME/mcp-server-macos-use"
if [ -d "$MCP_REPO" ]; then
    xcrun swift build -c release --package-path "$MCP_REPO"
    cp "$MCP_REPO/.build/release/mcp-server-macos-use" "$APP_BUNDLE/Contents/MacOS/mcp-server-macos-use"
    echo "Bundled mcp-server-macos-use"
else
    echo "Warning: mcp-server-macos-use not found at $MCP_REPO — skipping"
fi

# Build and bundle whatsapp-mcp
echo "Building whatsapp-mcp..."
MCP_WHATSAPP="$HOME/whatsapp-mcp-skill-macos"
if [ -d "$MCP_WHATSAPP" ]; then
    xcrun swift build -c release --package-path "$MCP_WHATSAPP"
    cp "$MCP_WHATSAPP/.build/release/whatsapp-mcp" "$APP_BUNDLE/Contents/MacOS/whatsapp-mcp"
    echo "Bundled whatsapp-mcp"
else
    echo "Warning: whatsapp-mcp not found at $MCP_WHATSAPP — skipping"
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
SWIFT_BUILD_DIR=$(xcrun swift build -c release --package-path Desktop --show-bin-path)
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
    # Copy browser overlay init scripts for Playwright MCP
    for f in browser-overlay-init.js browser-overlay-init-page.js browser-overlay-init-page.ts; do
        if [ -f "$ACP_BRIDGE_DIR/$f" ]; then
            cp -f "$ACP_BRIDGE_DIR/$f" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
        fi
    done
    echo "Copied acp-bridge to bundle"
fi

# Bundle Google Workspace MCP (Python)
WORKSPACE_MCP_REPO="$HOME/google_workspace_mcp"
WORKSPACE_MCP_BUNDLE="$APP_BUNDLE/Contents/Resources/google-workspace-mcp"
if [ -d "$WORKSPACE_MCP_REPO" ]; then
    echo "Bundling Google Workspace MCP..."
    mkdir -p "$WORKSPACE_MCP_BUNDLE"
    rsync -a --exclude='.git' --exclude='__pycache__' --exclude='.venv' \
        --exclude='*.pyc' --exclude='.ruff_cache' --exclude='tests' \
        --exclude='docs' --exclude='build' --exclude='dist' --exclude='*.egg-info' \
        "$WORKSPACE_MCP_REPO/" "$WORKSPACE_MCP_BUNDLE/"
    if command -v uv &>/dev/null; then
        uv venv "$WORKSPACE_MCP_BUNDLE/.venv" --python python3.12 --relocatable --quiet 2>&1 | tail -1 || true
        WORKSPACE_MCP_DEPS=$(python3.12 -c "
import tomllib
with open('$WORKSPACE_MCP_REPO/pyproject.toml', 'rb') as f:
    print(' '.join(tomllib.load(f)['project']['dependencies']))
")
        uv pip install --python "$WORKSPACE_MCP_BUNDLE/.venv/bin/python3" --link-mode copy $WORKSPACE_MCP_DEPS --quiet 2>&1 | tail -3 || true
        # Replace symlinks with actual binary for portability (venv python may symlink to uv-managed install)
        GWMCP_REAL_PYTHON=$(readlink -f "$WORKSPACE_MCP_BUNDLE/.venv/bin/python" 2>/dev/null)
        if [ -n "$GWMCP_REAL_PYTHON" ] && [ -f "$GWMCP_REAL_PYTHON" ] && [ -L "$WORKSPACE_MCP_BUNDLE/.venv/bin/python" ]; then
            GWMCP_MANAGED_DIR=$(dirname "$(dirname "$GWMCP_REAL_PYTHON")")
            rm -f "$WORKSPACE_MCP_BUNDLE/.venv/bin/python"
            cp "$GWMCP_REAL_PYTHON" "$WORKSPACE_MCP_BUNDLE/.venv/bin/python"
            rm -f "$WORKSPACE_MCP_BUNDLE/.venv/bin/python3" "$WORKSPACE_MCP_BUNDLE/.venv/bin/python3.12"
            # Create wrapper scripts that set PYTHONHOME so the bundled Python
            # can find its stdlib regardless of where the app is installed.
            for wrapper_name in python3 python3.12; do
                cat > "$WORKSPACE_MCP_BUNDLE/.venv/bin/$wrapper_name" << 'WRAPPER'
#!/bin/sh
VENV_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONHOME="$VENV_DIR"
exec "$VENV_DIR/bin/python" "$@"
WRAPPER
                chmod +x "$WORKSPACE_MCP_BUNDLE/.venv/bin/$wrapper_name"
            done
            # Copy libpython so @executable_path/../lib/libpython3.12.dylib resolves
            if [ -f "$GWMCP_MANAGED_DIR/lib/libpython3.12.dylib" ]; then
                cp "$GWMCP_MANAGED_DIR/lib/libpython3.12.dylib" "$WORKSPACE_MCP_BUNDLE/.venv/lib/libpython3.12.dylib"
            fi
            # Copy stdlib so Python can find encodings, os, etc. on machines without uv
            if [ -d "$GWMCP_MANAGED_DIR/lib/python3.12" ]; then
                rsync -a --ignore-existing "$GWMCP_MANAGED_DIR/lib/python3.12/" "$WORKSPACE_MCP_BUNDLE/.venv/lib/python3.12/"
            fi
            # Rewrite pyvenv.cfg so Python finds stdlib relative to venv, not the managed install
            printf 'home = bin\nimplementation = CPython\nversion_info = 3.12\ninclude-system-site-packages = false\n' > "$WORKSPACE_MCP_BUNDLE/.venv/pyvenv.cfg"
        fi
        echo "Bundled Google Workspace MCP with venv"
    else
        echo "Warning: uv not found — Google Workspace MCP will not work without dependencies"
    fi
else
    echo "Warning: Google Workspace MCP not found at $WORKSPACE_MCP_REPO — skipping"
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
