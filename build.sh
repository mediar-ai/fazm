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

# Copy acp-bridge
if [ -d "$ACP_BRIDGE_DIR/dist" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Resources/acp-bridge"
    cp -Rf "$ACP_BRIDGE_DIR/dist" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    cp -f "$ACP_BRIDGE_DIR/package.json" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    cp -Rf "$ACP_BRIDGE_DIR/node_modules" "$APP_BUNDLE/Contents/Resources/acp-bridge/"
    echo "Copied acp-bridge to bundle"
fi

# Copy gws binary (Google Workspace CLI)
GWS_BIN_DIR="Desktop/bin"
GWS_BIN="$GWS_BIN_DIR/gws"
if [ ! -f "$GWS_BIN" ]; then
    echo "Downloading gws binary..."
    mkdir -p "$GWS_BIN_DIR"
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        GWS_ARTIFACT="gws-aarch64-apple-darwin.tar.gz"
    else
        GWS_ARTIFACT="gws-x86_64-apple-darwin.tar.gz"
    fi
    curl -sL "https://github.com/googleworkspace/cli/releases/download/v0.5.0/${GWS_ARTIFACT}" | tar xz -C "$GWS_BIN_DIR" --strip-components=1 --include '*/gws'
    chmod +x "$GWS_BIN"
fi
if [ -f "$GWS_BIN" ]; then
    cp -f "$GWS_BIN" "$APP_BUNDLE/Contents/Resources/gws"
    chmod +x "$APP_BUNDLE/Contents/Resources/gws"
    echo "Copied gws binary to bundle"
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
