#!/usr/bin/env bash
# 比對 Sources/IAMPermissionCatalog/ 的權限快照和上游 repo 的 SSOT 是否逐字相同（byte-identical）。
# 「權限快照同步」PR 送出前跑一次；有差異就印 diff。
#
# 用法：bash scripts/diff-permission-snapshots.sh [context ...]
#   不給 context 就比對下面 SOURCES 表上的全部。
#   REF 環境變數指定上游的 branch、tag 或 commit，預設 main。
#
# 需要 gh 已登入、能讀上游 repo。只透過 GitHub API 讀檔，不連任何環境。
# exit：0 全部相同；1 有差異；2 用法錯誤或取檔失敗。
# 相容 macOS 內建 bash 3.2。
set -eo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REF="${REF:-main}"

# context|上游 repo|上游 SSOT 路徑。其他 context 的 SSOT 路徑確認後再加進來。
SOURCES="
MCPContext|Mendesky/MCPContext|Sources/MendeskyTools/MCPContext.permissions.yaml
"

lookup() {
    echo "${SOURCES}" | awk -F'|' -v c="$1" '$1 == c { print; exit }'
}

if [ "$#" -eq 0 ]; then
    set -- $(echo "${SOURCES}" | awk -F'|' 'NF == 3 { print $1 }')
fi

command -v gh >/dev/null 2>&1 || { echo "找不到 gh" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

status=0
for context in "$@"; do
    row="$(lookup "${context}")"
    if [ -z "${row}" ]; then
        echo "${context}：SOURCES 表上沒有這個 context" >&2
        exit 2
    fi
    upstream_repo="$(echo "${row}" | cut -d'|' -f2)"
    upstream_path="$(echo "${row}" | cut -d'|' -f3)"
    snapshot="${REPO}/Sources/IAMPermissionCatalog/${context}.permissions.yaml"
    upstream="${TMP}/${context}.permissions.yaml"

    if [ ! -f "${snapshot}" ]; then
        echo "${context}：找不到快照 ${snapshot}" >&2
        status=1
        continue
    fi
    if ! gh api -H "Accept: application/vnd.github.raw" \
        "repos/${upstream_repo}/contents/${upstream_path}?ref=${REF}" > "${upstream}"; then
        echo "${context}：讀不到 ${upstream_repo}@${REF}:${upstream_path}" >&2
        exit 2
    fi

    if cmp -s "${upstream}" "${snapshot}"; then
        echo "${context}：相同（${upstream_repo}@${REF}）"
    else
        echo "${context}：不同（${upstream_repo}@${REF}，- 上游、+ 快照）"
        diff -u "${upstream}" "${snapshot}" || true
        status=1
    fi
done
exit "${status}"
