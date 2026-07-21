#!/usr/bin/env bash
# Sync the version shown on the marketing site from the repo's VERSION file.
#
# The version appears in exactly three places in site/public/index.html:
#   1. the JSON-LD "softwareVersion" field
#   2. the CTA meta line ("v0.3.0 · MIT · macOS 14+ …")
#   3. the footer changelog link ("Changelog · v0.3.0")
# This script rewrites all three and then VERIFIES each landed, so a future
# markup change that breaks a pattern fails loudly instead of deploying a
# stale version (which is how 0.2.1 and 0.3.0 shipped with the site stuck
# on v0.2.0).
#
# Run from anywhere; used by the release workflow's deploy-site job and safe
# to run locally before a manual `cd site && wrangler deploy`.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
HTML="site/public/index.html"

perl -pi -e "s/\"softwareVersion\": \"[0-9]+\\.[0-9]+\\.[0-9]+\"/\"softwareVersion\": \"$VERSION\"/" "$HTML"
perl -pi -e "s/v[0-9]+\\.[0-9]+\\.[0-9]+(&nbsp;·)/v$VERSION\$1/" "$HTML"
perl -pi -e "s/(Changelog&nbsp;·&nbsp;)v[0-9]+\\.[0-9]+\\.[0-9]+/\${1}v$VERSION/" "$HTML"

fail() { echo "sync-site-version: $1 not found in $HTML after substitution" >&2; exit 1; }
grep -q "\"softwareVersion\": \"$VERSION\"" "$HTML" || fail "JSON-LD softwareVersion $VERSION"
grep -q "v$VERSION&nbsp;·" "$HTML"               || fail "CTA meta v$VERSION"
grep -q "Changelog&nbsp;·&nbsp;v$VERSION" "$HTML" || fail "footer changelog link v$VERSION"

echo "site version synced to $VERSION"
