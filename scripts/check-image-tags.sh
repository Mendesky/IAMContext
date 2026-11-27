#!/usr/bin/env bash
# release-docker.yml 推 image 之前的檢查：metadata-action 產生的 image tag 只能有 <IMAGE>:<tag 名稱> 這一個
# （設定或 action 版本變了也不會偷偷推 latest 或別的 tag）。
# 用法：TAGS=<steps.meta.outputs.tags> WANT=<IMAGE>:<tag 名稱> bash scripts/check-image-tags.sh
# 只有一個且完全相同時 exit 0，否則 exit 1。空行忽略。
set -euo pipefail
: "${WANT:?WANT is required}"
got="$(printf '%s\n' "${TAGS:-}" | sed '/^[[:space:]]*$/d')"
if [ "$got" != "$WANT" ]; then
    echo "::error::要推的 image tag 應該只有 ${WANT}，實際是：${got:-（沒有）}" >&2
    exit 1
fi
echo "✅ 只推 ${WANT}"
