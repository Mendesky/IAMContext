#!/usr/bin/env bash
# 比對 Sources/IAMPermissionCatalog/ 的權限快照和上游 repo 的 SSOT 是否逐字相同（byte-identical）。
# 手動執行（CI 讀不到其他私有 repo）：「權限快照同步」PR 送出前跑一次；有差異就印 diff。
#
# 用法：bash scripts/diff-permission-snapshots.sh [context ...]
#   不給 context 就比對下面 SOURCES 表上的全部。
#   REF 環境變數指定上游的 branch、tag 或 commit，預設 main。從上游開發分支同步時，記得把 REF 設成那個分支。
#
# 需要 gh 已登入、能讀上游 repo。只透過 GitHub API 讀檔，不連任何環境。
# exit：0 全部相同；1 有差異（且沒有錯誤）；2 用法錯誤、快照不存在或取檔失敗（優先於 1）。
# 每個 context 都會比對完才結束，最後一行印總結。
# 相容 macOS 內建 bash 3.2。
set -eo pipefail
set -f  # context 名稱不做 glob 展開

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REF="${REF:-main}"

# context|上游 repo|上游 SSOT 路徑。其他 context 的 SSOT 路徑確認後再加進來。
SOURCES="
MCPContext|Mendesky/MCPContext|Sources/MendeskyTools/MCPContext.permissions.yaml
"

case "${REF}" in
    "" | *[!A-Za-z0-9._/-]*)
        echo "REF 只能含英數字和 . _ / -：${REF}" >&2
        exit 2
        ;;
esac

lookup() {
    echo "${SOURCES}" | awk -F'|' -v c="$1" 'NF == 3 && $1 == c { print; exit }'
}

if [ "$#" -eq 0 ]; then
    set -- $(echo "${SOURCES}" | awk -F'|' 'NF == 3 { print $1 }')
    if [ "$#" -eq 0 ]; then
        echo "SOURCES 表沒有任何有效的列" >&2
        exit 2
    fi
fi

command -v gh >/dev/null 2>&1 || { echo "找不到 gh" >&2; exit 2; }

TMP="$(mktemp -d)" || { echo "無法建立暫存目錄" >&2; exit 2; }
trap 'rm -rf "${TMP}"' EXIT

differ=0
failed=0
for context in "$@"; do
    row="$(lookup "${context}")"
    if [ -z "${row}" ]; then
        echo "${context}：SOURCES 表上沒有這個 context" >&2
        failed=1
        continue
    fi
    upstream_repo="$(echo "${row}" | cut -d'|' -f2)"
    upstream_path="$(echo "${row}" | cut -d'|' -f3)"
    snapshot_rel="Sources/IAMPermissionCatalog/${context}.permissions.yaml"
    snapshot="${REPO}/${snapshot_rel}"
    upstream="${TMP}/${context}.permissions.yaml"
    label="${upstream_repo}@${REF}:${upstream_path}"

    if [ ! -f "${snapshot}" ]; then
        echo "${context}：找不到快照 ${snapshot_rel}" >&2
        failed=1
        continue
    fi
    # ref 用 -f 傳，由 gh 編碼成 query string。gh 在 HTTP 錯誤時 exit 非 0。
    if ! gh api --method GET -H "Accept: application/vnd.github.raw" \
        "repos/${upstream_repo}/contents/${upstream_path}" -f ref="${REF}" > "${upstream}"; then
        echo "${context}：讀不到 ${label}" >&2
        failed=1
        continue
    fi
    # 路徑若是目錄，API 回 JSON 清單而不是檔案內容；空內容也當成取檔失敗。
    if [ ! -s "${upstream}" ] || [ "$(head -c 1 "${upstream}")" = "[" ]; then
        echo "${context}：${label} 不是有內容的檔案" >&2
        failed=1
        continue
    fi

    rc=0
    cmp -s "${upstream}" "${snapshot}" || rc=$?
    case "${rc}" in
        0)
            echo "${context}：相同（${label}）"
            ;;
        1)
            echo "${context}：不同（- 上游、+ 快照）"
            diff -u --label "${label}" --label "${snapshot_rel}" "${upstream}" "${snapshot}" || true
            differ=1
            ;;
        *)
            echo "${context}：比對失敗（cmp exit ${rc}）" >&2
            failed=1
            ;;
    esac
done

if [ "${failed}" -ne 0 ]; then
    echo "結果：有 context 無法比對（exit 2）" >&2
    exit 2
elif [ "${differ}" -ne 0 ]; then
    echo "結果：有差異（exit 1）"
    exit 1
fi
echo "結果：全部相同"
