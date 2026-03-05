#!/bin/bash
set -e

# =============================================================================
# Deploy appcast.xml to the latest GitHub Release
# Generates appcast.xml and uploads it as a release asset so that
# https://github.com/m13v/fazm/releases/latest/download/appcast.xml
# always serves the current appcast
# =============================================================================

GITHUB_REPO="m13v/fazm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPCAST_FILE="/tmp/appcast.xml"

echo "Deploying appcast.xml to latest GitHub release..."

# Step 1: Generate appcast.xml
"$SCRIPT_DIR/generate-appcast.sh" "$APPCAST_FILE"

# Step 2: Get the latest release tag
LATEST_TAG=$(gh release list --repo "$GITHUB_REPO" --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null)

if [ -z "$LATEST_TAG" ]; then
    echo "Error: No releases found for $GITHUB_REPO"
    rm -f "$APPCAST_FILE"
    exit 1
fi

echo "Uploading appcast.xml to release: $LATEST_TAG"

# Step 3: Upload appcast.xml (--clobber overwrites if it already exists)
gh release upload "$LATEST_TAG" "$APPCAST_FILE" \
    --repo "$GITHUB_REPO" \
    --clobber

# Cleanup
rm -f "$APPCAST_FILE"

echo "Done! Appcast available at:"
echo "  https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"
