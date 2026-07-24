#!/bin/bash
# Verifies every non-excluded DB table has a tableAnnotation in ChatPrompts.swift.
# Run as part of build.sh / run.sh before the Swift build step.
# Exit code 1 = missing annotation(s); exit code 0 = all good.

set -e

CHAT_PROMPTS="Desktop/Sources/Chat/ChatPrompts.swift"
MIGRATIONS="Desktop/Sources/Rewind/Core/RewindDatabase.swift"

# Tables that are intentionally excluded from the schema prompt
EXCLUDED=(
    "migration_status"
    "task_dedup_log"
    "ocr_texts"
    "ocr_occurrences"
)

# Extract all table names defined in migrations
TABLES=$(grep 'create(table:' "$MIGRATIONS" | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u)

MISSING=()
for table in $TABLES; do
    # Skip excluded tables
    excluded=false
    for ex in "${EXCLUDED[@]}"; do
        [[ "$table" == "$ex" ]] && excluded=true && break
    done
    $excluded && continue

    # Check tableAnnotations has an entry for this table
    if ! grep -q "\"$table\":" "$CHAT_PROMPTS"; then
        MISSING+=("$table")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "❌ Schema docs missing in ChatPrompts.tableAnnotations:"
    for t in "${MISSING[@]}"; do
        echo "   - $t"
    done
    echo "   Add a one-line description to ChatPrompts.tableAnnotations before building."
    exit 1
fi

echo "✅ All DB tables have schema annotations."
