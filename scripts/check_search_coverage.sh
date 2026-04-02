#!/bin/bash
# Verifies every settingId used in the settings UI has a matching entry in the
# search index (SettingsSearchItem.allSearchableItems) and vice versa.
# Run as part of build.sh / run.sh before the Swift build step.
# Exit code 1 = mismatch(es); exit code 0 = all good.

set -e

SIDEBAR="Desktop/Sources/MainWindow/SettingsSidebar.swift"
SETTINGS_PAGE="Desktop/Sources/MainWindow/Pages/SettingsPage.swift"
SHORTCUTS="Desktop/Sources/MainWindow/Pages/ShortcutsSettingsSection.swift"

# Search-only IDs that navigate to a section tab without highlighting a specific card
SECTION_LEVEL_IDS=(
    "permissions.permissions"
    "dictionary.dictionary"
)

# Extract settingIds from the search index
SEARCH_IDS=$(grep -oE 'settingId: "[^"]+"' "$SIDEBAR" | sed 's/settingId: "//;s/"//' | sort -u)

# Extract settingIds from the UI
UI_IDS_PAGE=$(grep -oE 'settingId: "[^"]+"' "$SETTINGS_PAGE" | sed 's/settingId: "//;s/"//' | sort -u)
UI_IDS_SHORTCUTS=$(grep -oE 'settingId: "[^"]+"' "$SHORTCUTS" | sed 's/settingId: "//;s/"//' | sort -u)
UI_IDS=$(echo -e "$UI_IDS_PAGE\n$UI_IDS_SHORTCUTS" | sort -u)

is_section_level() {
    for ex in "${SECTION_LEVEL_IDS[@]}"; do
        [[ "$1" == "$ex" ]] && return 0
    done
    return 1
}

# Find UI IDs missing from search
MISSING_FROM_SEARCH=()
while IFS= read -r id; do
    [ -z "$id" ] && continue
    if ! echo "$SEARCH_IDS" | grep -qx "$id"; then
        MISSING_FROM_SEARCH+=("$id")
    fi
done <<< "$UI_IDS"

# Find search IDs that don't exist in UI (excluding section-level items)
ORPHAN_SEARCH=()
while IFS= read -r id; do
    [ -z "$id" ] && continue
    is_section_level "$id" && continue
    if ! echo "$UI_IDS" | grep -qx "$id"; then
        ORPHAN_SEARCH+=("$id")
    fi
done <<< "$SEARCH_IDS"

FAILED=false

if [ ${#MISSING_FROM_SEARCH[@]} -gt 0 ]; then
    echo "❌ Settings search coverage: UI settings missing from search index:"
    for id in "${MISSING_FROM_SEARCH[@]}"; do
        echo "   - $id"
    done
    echo "   Add a SettingsSearchItem entry in SettingsSidebar.swift for each missing ID."
    FAILED=true
fi

if [ ${#ORPHAN_SEARCH[@]} -gt 0 ]; then
    echo "❌ Settings search coverage: search entries with no matching UI element:"
    for id in "${ORPHAN_SEARCH[@]}"; do
        echo "   - $id"
    done
    echo "   Remove orphan entries from allSearchableItems or add the UI element."
    FAILED=true
fi

if $FAILED; then
    exit 1
fi

echo "✅ All settings have matching search entries."
