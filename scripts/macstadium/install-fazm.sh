#!/bin/bash
# Download and install Fazm on the MacStadium Mac mini
# Usage: ./scripts/macstadium/install-fazm.sh [dmg-url]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../.env"

DMG_URL="${1:-https://github.com/m13v/fazm/releases/latest/download/Fazm.dmg}"
REMOTE_CMD="$(cat <<'REMOTE'
set -euo pipefail
echo "[1/7] Downloading Fazm..."
curl -L --progress-bar -o /tmp/Fazm.dmg "$DMG_URL"

echo "[2/7] Mounting DMG..."
MOUNT_POINT=$(hdiutil attach -nobrowse -plist /tmp/Fazm.dmg | python3 -c "
import sys, plistlib
pl = plistlib.load(sys.stdin.buffer)
for e in pl.get('system-entities', []):
    mp = e.get('mount-point')
    if mp:
        print(mp)
        break
")
echo "Mounted at: $MOUNT_POINT"

# Remove any prior install so a fresh, user-owned copy lands cleanly.
# Prior versions of this script chowned the bundle to root:wheel, which
# forces Sparkle to prompt for an admin password on every auto-update.
echo "[3/7] Removing prior Fazm.app (if present)..."
if [ -e /Applications/Fazm.app ]; then
    sudo rm -rf /Applications/Fazm.app
fi

echo "[4/7] Installing Fazm.app (owned by the current admin user)..."
# /Applications is mode 775 root:admin, so any admin user can write here
# without sudo. We deliberately do NOT use `sudo ditto` so the bundle
# inherits the current user's uid + the admin gid.
ditto "$MOUNT_POINT/Fazm.app" "/Applications/Fazm.app"

echo "[5/7] Ensuring bundle is owned by the current user (so Sparkle can update in place)..."
chown -R "$(id -un):admin" "/Applications/Fazm.app"

echo "[6/7] Removing quarantine flag..."
xattr -r -d com.apple.quarantine "/Applications/Fazm.app" 2>/dev/null || true

echo "[7/7] Unmounting and cleaning up..."
hdiutil detach "$MOUNT_POINT" -quiet
rm /tmp/Fazm.dmg

echo "Done. Fazm installed to /Applications, owned by $(stat -f '%Su:%Sg' /Applications/Fazm.app)."
REMOTE
)"

sshpass -p "$MACSTADIUM_PASSWORD" ssh -o StrictHostKeyChecking=no "$MACSTADIUM_USER@$MACSTADIUM_HOST" \
    "export DMG_URL='$DMG_URL'; $REMOTE_CMD"
