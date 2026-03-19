#!/bin/bash
# Promote a desktop release to the next channel
#
# Channel progression: staging → beta → stable
#
# Usage:
#   ./scripts/promote_release.sh v0.9.1+57-macos-staging
#
# Environment:
#   RELEASE_SECRET   - API shared secret (required)
#   FAZM_BACKEND_URL - Backend URL (default: https://fazm-backend-472661769323.us-east5.run.app)

set -e

# Load .env if available
if [ -f ".env" ]; then
    set -a
    source .env
    set +a
elif [ -f "../.env" ]; then
    set -a
    source "../.env"
    set +a
fi

BACKEND_URL="${FAZM_BACKEND_URL:-https://fazm-backend-472661769323.us-east5.run.app}"
RELEASE_SECRET="${RELEASE_SECRET:-}"

TAG="${1:-}"

if [ -z "$TAG" ]; then
    echo "Usage: $0 <tag>"
    echo ""
    echo "Promotes a release to the next channel:"
    echo "  staging → beta → stable"
    echo ""
    echo "Example:"
    echo "  $0 v0.9.1+57-macos-staging"
    exit 1
fi

if [ -z "$RELEASE_SECRET" ]; then
    echo "Error: RELEASE_SECRET environment variable is required"
    exit 1
fi

echo "Promoting release: $TAG"
echo "  Backend: $BACKEND_URL"
echo ""

# If promoting from staging, first trigger a full production build (with DMG)
# before touching Firestore channels. The production build uses a non-staging tag.
IS_STAGING_TAG=false
if echo "$TAG" | grep -q "\-staging$"; then
    IS_STAGING_TAG=true
fi

if [ "$IS_STAGING_TAG" = "true" ]; then
    # Derive production tag: v1.0.1+69-macos-staging -> v1.0.1+69-macos
    PROD_TAG=$(echo "$TAG" | sed 's/-staging$//')

    if ! command -v gh &>/dev/null; then
        echo "Error: gh CLI is required to trigger a production build"
        exit 1
    fi

    # Check if a production build for this tag already exists on GitHub
    REPO=$(gh repo view m13v/fazm --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "m13v/fazm")
    if gh release view "$PROD_TAG" --repo "$REPO" &>/dev/null; then
        echo "✓ Production build $PROD_TAG already exists — skipping rebuild"
    else
        echo "Triggering production build: $PROD_TAG"
        COMMIT=$(gh release view "$TAG" --repo "$REPO" --json targetCommitish --jq .targetCommitish 2>/dev/null || \
                 git rev-parse HEAD 2>/dev/null || echo "")
        if [ -z "$COMMIT" ]; then
            echo "Error: Could not determine commit SHA for $TAG"
            exit 1
        fi
        # Push the production tag to trigger Codemagic
        gh api "repos/$REPO/git/refs" \
            --method POST \
            -f ref="refs/tags/$PROD_TAG" \
            -f sha="$COMMIT" \
            --jq '.ref' 2>/dev/null && \
            echo "✓ Production tag $PROD_TAG pushed — Codemagic build triggered" || \
            echo "⚠ Could not push tag (may already exist). Check Codemagic manually."
        echo ""
        echo "NOTE: Wait for the production build to complete before the beta release"
        echo "      is available for fresh installs (DMG). Auto-update (Sparkle ZIP)"
        echo "      will be available once the Firestore channel is promoted below."
    fi

    # Promote using the production tag in Firestore
    TAG="$PROD_TAG"
fi

RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X PATCH \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $RELEASE_SECRET" \
    -d "{\"tag\": \"$TAG\"}" \
    "$BACKEND_URL/api/releases/promote")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Release promoted successfully"
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
else
    echo "✗ Failed to promote release (HTTP $HTTP_CODE)"
    echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
    exit 1
fi

# When promoted to beta, update desktop/latest.json on GCS so the stub
# installer serves this version to new users.
NEW_CHANNEL=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin).get('new_channel',''))" 2>/dev/null)
if [ "$NEW_CHANNEL" = "beta" ]; then
    # Extract version from tag: v1.0.1+65-macos -> 1.0.1
    VERSION=$(echo "$TAG" | sed 's/^v//' | sed 's/+.*//')
    BUCKET="fazm-prod-releases"

    echo ""
    echo "Updating desktop/latest.json to v$VERSION..."
    if gcloud storage cp "gs://$BUCKET/desktop/$VERSION/latest.json" "gs://$BUCKET/desktop/latest.json" \
        --cache-control="no-cache, max-age=0" 2>/dev/null; then
        echo "✓ desktop/latest.json updated — new installs will get v$VERSION"
    else
        echo "⚠ Failed to update desktop/latest.json. Update manually:"
        echo "  gcloud storage cp gs://$BUCKET/desktop/$VERSION/latest.json gs://$BUCKET/desktop/latest.json --cache-control='no-cache, max-age=0'"
    fi
fi
