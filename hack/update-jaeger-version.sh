#!/usr/bin/env bash
#
# 更新 docs/en/ MDX 文档中的 Jaeger 版本引用。
# 用法：./hack/update-jaeger-version.sh <旧版本> <新版本>
# 示例：./hack/update-jaeger-version.sh 2.20.0 2.24.0
#
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "用法：$0 <旧版本> <新版本>"
  echo "示例：$0 2.20.0 2.24.0"
  exit 1
fi

# 兼容带 v 和不带 v 的版本参数，并统一为不带 v 的格式。
OLD_VERSION="${1#v}"
NEW_VERSION="${2#v}"
VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

if [[ ! "$OLD_VERSION" =~ $VERSION_PATTERN || ! "$NEW_VERSION" =~ $VERSION_PATTERN ]]; then
  echo "错误：版本号必须使用 x.y.z 或 vx.y.z 格式。" >&2
  exit 1
fi

if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
  echo "错误：旧版本和新版本不能相同。" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS_DIR="$REPO_ROOT/docs/en"
MIGRATION_FILE="$DOCS_DIR/migrating/migrating-from-acp-tracing.mdx"

if [[ ! -d "$DOCS_DIR" ]]; then
  echo "错误：未找到文档目录 $DOCS_DIR" >&2
  exit 1
fi

if [[ ! -f "$MIGRATION_FILE" ]]; then
  echo "错误：未找到迁移文档 $MIGRATION_FILE" >&2
  exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
  echo "错误：更新文档需要 perl。" >&2
  exit 1
fi

OLD_LINK_PREFIX="https://github.com/alauda-mesh/jaeger/tree/v${OLD_VERSION}/"
NEW_LINK_PREFIX="https://github.com/alauda-mesh/jaeger/tree/v${NEW_VERSION}/"

echo "正在更新 Jaeger 版本：$OLD_VERSION -> $NEW_VERSION"

# 仅更新指定 Jaeger 仓库 tree 链接中的版本，不修改其他版本说明。
link_file_count=0
while IFS= read -r -d '' file; do
  if grep -Fq -- "$OLD_LINK_PREFIX" "$file"; then
    OLD_LINK_PREFIX="$OLD_LINK_PREFIX" NEW_LINK_PREFIX="$NEW_LINK_PREFIX" \
      perl -pi -e 's{\Q$ENV{OLD_LINK_PREFIX}\E}{$ENV{NEW_LINK_PREFIX}}g' "$file"
    echo "  已更新链接：${file#"$REPO_ROOT/"}"
    link_file_count=$((link_file_count + 1))
  fi
done < <(find "$DOCS_DIR" -type f -name '*.mdx' -print0)

# 迁移文档中的版本号和镜像 tag 都应随 Jaeger 版本一起更新。
migration_updated=0
if grep -Fq -- "$OLD_VERSION" "$MIGRATION_FILE"; then
  OLD_VERSION="$OLD_VERSION" NEW_VERSION="$NEW_VERSION" \
    perl -pi -e 's{(?<![0-9.])\Q$ENV{OLD_VERSION}\E(?![0-9.])}{$ENV{NEW_VERSION}}g' "$MIGRATION_FILE"
  echo "  已更新迁移文档：${MIGRATION_FILE#"$REPO_ROOT/"}"
  migration_updated=1
fi

echo "更新完成：$link_file_count 个文件中的链接、$migration_updated 个迁移文档已更新。"
