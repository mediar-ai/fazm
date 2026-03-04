#!/bin/bash
set -e

# =============================================================================
# Generate Sparkle 2.0 appcast.xml from GitHub Releases
# Reads the last 5 releases from m13v/fazm and produces a valid appcast
# =============================================================================

GITHUB_REPO="m13v/fazm"
OUTPUT_FILE="${1:-appcast.xml}"

echo "Generating appcast.xml from $GITHUB_REPO releases..."

# Get recent releases as JSON
RELEASES_JSON=$(gh release list --repo "$GITHUB_REPO" --limit 5 --json tagName,publishedAt,name,isDraft,isPrerelease 2>/dev/null)

if [ -z "$RELEASES_JSON" ] || [ "$RELEASES_JSON" = "[]" ]; then
    echo "Error: No releases found for $GITHUB_REPO"
    exit 1
fi

# Start building the XML
cat > "$OUTPUT_FILE" <<'XMLHEADER'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Fazm</title>
    <link>https://github.com/m13v/fazm/releases</link>
    <description>Fazm Desktop Updates</description>
    <language>en</language>
XMLHEADER

# Process each release
echo "$RELEASES_JSON" | python3 -c "
import json, sys
releases = json.load(sys.stdin)
for r in releases:
    if not r.get('isDraft', False):
        print(r['tagName'])
" | while read -r TAG; do
    echo "  Processing release: $TAG"

    # Get release details including assets
    RELEASE_DETAIL=$(gh release view "$TAG" --repo "$GITHUB_REPO" --json tagName,publishedAt,body,assets 2>/dev/null)

    if [ -z "$RELEASE_DETAIL" ]; then
        echo "    Warning: Could not fetch details for $TAG, skipping"
        continue
    fi

    # Extract info using python
    ITEM_XML=$(echo "$RELEASE_DETAIL" | python3 -c "
import json, sys, re
from datetime import datetime, timezone

data = json.load(sys.stdin)
tag = data['tagName']
pub_date = data.get('publishedAt', '')
body = data.get('body', '')
assets = data.get('assets', [])

# Find the .zip asset (Sparkle needs ZIP, not DMG)
zip_asset = None
for a in assets:
    if a['name'].endswith('.zip') and 'appcast' not in a['name'].lower():
        zip_asset = a
        break

if not zip_asset:
    sys.exit(0)  # No ZIP asset, skip this release

download_url = zip_asset['url']
file_size = zip_asset['size']

# Parse version from tag: v0.0.7+7-macos -> 0.0.7, build 7
# Also handle simpler tags like v0.0.7
version_match = re.match(r'v?(\d+\.\d+\.\d+)(?:\+(\d+))?', tag)
if not version_match:
    sys.exit(0)

version = version_match.group(1)
build_number = version_match.group(2)
if not build_number:
    # Calculate build number from version: 0.0.7 -> 7, 1.2.3 -> 1002003
    parts = version.split('.')
    bn = 0
    for p in parts:
        bn = bn * 1000 + int(p)
    build_number = str(bn)

# Extract EdDSA signature from release body if present
ed_sig = ''
sig_match = re.search(r'edSignature[\"=:]\s*[\"]*([A-Za-z0-9+/=]{40,})', body or '')
if sig_match:
    ed_sig = sig_match.group(1)

# Format date as RFC 2822
try:
    dt = datetime.fromisoformat(pub_date.replace('Z', '+00:00'))
    rfc2822 = dt.strftime('%a, %d %b %Y %H:%M:%S +0000')
except:
    rfc2822 = pub_date

# Build enclosure attributes
enclosure_attrs = f'url=\"{download_url}\"'
if ed_sig:
    enclosure_attrs += f'\\n                 sparkle:edSignature=\"{ed_sig}\"'
enclosure_attrs += f'\\n                 length=\"{file_size}\"'
enclosure_attrs += '\\n                 type=\"application/octet-stream\"'

print(f'''    <item>
      <title>Version {version}</title>
      <pubDate>{rfc2822}</pubDate>
      <sparkle:version>{build_number}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure {enclosure_attrs}/>
    </item>''')
" 2>/dev/null)

    if [ -n "$ITEM_XML" ]; then
        echo "$ITEM_XML" >> "$OUTPUT_FILE"
    fi
done

# Close the XML
cat >> "$OUTPUT_FILE" <<'XMLFOOTER'
  </channel>
</rss>
XMLFOOTER

echo "Generated: $OUTPUT_FILE"
