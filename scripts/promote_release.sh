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

# Extract version from tag: v1.1.2+86-macos-staging -> 1.1.2
VERSION=$(echo "$TAG" | sed 's/^v//' | sed 's/+.*//')

# Fetch current state from the list endpoint
echo "Fetching current release state..."
LIST_RESP=$(curl -s "$BACKEND_URL/api/releases" 2>/dev/null)
CURRENT_CHANNEL=$(echo "$LIST_RESP" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('releases', []):
    if r['tag'] == '$TAG':
        print(r['channel'])
        break
else:
    print('NOT_FOUND')
" 2>/dev/null || echo "UNKNOWN")

if [ "$CURRENT_CHANNEL" = "NOT_FOUND" ]; then
    echo "✗ Release $TAG not found in Firestore. Has it been registered?"
    exit 1
fi

if [ "$CURRENT_CHANNEL" = "stable" ]; then
    echo "✗ Release $TAG is already on stable — nothing to promote."
    exit 0
fi

# Determine next channel
case "$CURRENT_CHANNEL" in
    staging) NEXT_CHANNEL="beta" ;;
    beta)    NEXT_CHANNEL="stable" ;;
    *)       echo "✗ Unknown channel: $CURRENT_CHANNEL"; exit 1 ;;
esac

echo "  Current channel: $CURRENT_CHANNEL"
echo "  Will promote to: $NEXT_CHANNEL"
echo ""

# Confirm unless --yes flag is passed
if [ "${2:-}" != "--yes" ]; then
    read -p "Proceed? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Promote in Firestore (the backend handles deactivating previous releases
# on the target channel automatically)
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

# When promoted to beta or stable, update desktop/latest.json on GCS so the
# stub installer serves this version to new users.
NEW_CHANNEL=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin).get('new_channel',''))" 2>/dev/null)
if [ "$NEW_CHANNEL" = "beta" ] || [ "$NEW_CHANNEL" = "stable" ]; then
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
