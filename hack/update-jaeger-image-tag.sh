#!/usr/bin/env bash
#
# Update Jaeger-related image tags in docs/en/ MDX files.
# Matches build-harbor.alauda.cn/<any-path>:<old-tag> and replaces with the new tag.
# Usage: ./hack/update-jaeger-image-tag.sh <new-tag>
# Example: ./hack/update-jaeger-image-tag.sh 2.17.0-r0
#
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <new-tag>"
  echo "Example: $0 2.17.0-r0"
  exit 1
fi

NEW_TAG="$1"
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

# Pattern: build-harbor.alauda.cn/<path>:<any-tag>
REPLACEMENT_SED='s|\(build-harbor\.alauda\.cn/[^:]*:\)[^ \\\"'"'"')}\n]*|\1'"${NEW_TAG}"'|g'

echo "Updating image tags to: $NEW_TAG"
echo "Scanning: $DOCS_DIR"

count=0
while IFS= read -r -d '' file; do
  if grep -qE 'build-harbor\.alauda\.cn/' "$file"; then
    sedi "$REPLACEMENT_SED" "$file"
    echo "  Updated: ${file#"$DOCS_DIR/"}"
    count=$((count + 1))
  fi
done < <(find "$DOCS_DIR" -name '*.mdx' -print0)

echo "Done. $count file(s) updated."
