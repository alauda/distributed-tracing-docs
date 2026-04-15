#!/usr/bin/env bash
#
# Update Jaeger version references in docs/en/ MDX files.
# Usage: ./hack/update-jaeger-version.sh <old-version> <new-version>
# Example: ./hack/update-jaeger-version.sh v2.16.0 v2.17.0
#
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <old-version> <new-version>"
  echo "Example: $0 v2.16.0 v2.17.0"
  exit 1
fi

OLD_VERSION="$1"
NEW_VERSION="$2"
DOCS_DIR="$(cd "$(dirname "$0")/.." && pwd)/docs/en"

if [[ ! -d "$DOCS_DIR" ]]; then
  echo "Error: docs/en directory not found at $DOCS_DIR"
  exit 1
fi

# Cross-platform sed in-place: macOS requires -i '', GNU requires -i
sedi() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

echo "Replacing Jaeger version: $OLD_VERSION -> $NEW_VERSION"
echo "Scanning: $DOCS_DIR"

count=0
while IFS= read -r -d '' file; do
  if grep -q "$OLD_VERSION" "$file"; then
    sedi "s|${OLD_VERSION}|${NEW_VERSION}|g" "$file"
    echo "  Updated: ${file#"$DOCS_DIR/"}"
    count=$((count + 1))
  fi
done < <(find "$DOCS_DIR" -name '*.mdx' -print0)

echo "Done. $count file(s) updated."
