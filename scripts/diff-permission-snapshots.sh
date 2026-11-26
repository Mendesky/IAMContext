#!/usr/bin/env bash
# 比對 Sources/IAMPermissionCatalog/ 的權限快照和上游 repo 的 SSOT 是否逐字相同（byte-identical）。
# 手動執行（CI 讀不到其他私有 repo）：「權限快照同步」PR 送出前跑一次；有差異就印 diff。
#
# 用法：bash scripts/diff-permission-snapshots.sh [context ...]
#   不給 context 就比對下面 SOURCES 表上的全部。
#   REF 環境變數指定上游的 branch、tag 或 commit，預設 main。從上游開發分支同步時，記得把 REF 設成那個分支。
#
# 需要 gh 已登入、能讀上游 repo。只透過 GitHub API 讀檔，不連任何環境。
# exit：0 全部相同；1 有差異（且沒有任何錯誤）；
#       2 無法比對：用法錯誤（REF、context、SOURCES 表格式）、缺 gh、快照不存在、上游不是檔案或讀不到、cmp／diff 出錯。2 優先於 1。
# 開始比對後，每個 context 都會比對完才結束，最後一行印總結（相同或有差異印到 stdout，無法比對印到 stderr）。
# 比對開始前的錯誤（REF、SOURCES 表、缺 gh、建不了暫存目錄）直接 exit 2，不印總結。
# 相容 macOS 內建 bash 3.2。
set -eo pipefail
set -f            # context 名稱不做 glob 展開
export LC_ALL=C   # REF 白名單的字元範圍只比 ASCII

REPO="$(cd "$(dirname "$0")/.." && pwd)"
REF="${REF:-main}"

# context|上游 repo|上游 SSOT 路徑。其他 context 的 SSOT 路徑確認後再加進來。欄位內不能有 |。
SOURCES="
MCPContext|Mendesky/MCPContext|Sources/MendeskyTools/MCPContext.permissions.yaml
OIDCContext|Mendesky/OIDCContext|Sources/OIDCAuthorization/OIDCContext.permissions.yaml
"

case "${REF}" in
    "" | -* | /* | *..* | *[!A-Za-z0-9._/-]*)
        echo "REF 只能含英數字和 . _ / -，不能以 - 或 / 開頭、不能含 ..：${REF}" >&2
        exit 2
        ;;
esac

# 表上每個非空列都要剛好三個非空欄位，context 不能重複，否則是表本身寫錯。
bad_rows="$(awk -F'|' 'NF > 0 && (NF != 3 || $1 == "" || $2 == "" || $3 == "" || seen[$1]++)' <<< "${SOURCES}")"
if [ -n "${bad_rows}" ]; then
    printf 'SOURCES 表格式錯誤（要剛好三個非空欄位、context 不能重複）：\n%s\n' "${bad_rows}" >&2
    exit 2
fi

lookup() {
    C="$1" awk -F'|' 'NF == 3 && $1 == ENVIRON["C"] { print }' <<< "${SOURCES}"
}

if [ "$#" -eq 0 ]; then
    set -- $(awk -F'|' 'NF == 3 { print $1 }' <<< "${SOURCES}")
    if [ "$#" -eq 0 ]; then
        echo "SOURCES 表沒有任何列" >&2
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
        printf '%s：SOURCES 表上沒有這個 context\n' "${context}" >&2
        failed=1
        continue
    fi
    upstream_repo="$(printf '%s\n' "${row}" | cut -d'|' -f2)"
    upstream_path="$(printf '%s\n' "${row}" | cut -d'|' -f3)"
    snapshot_rel="Sources/IAMPermissionCatalog/${context}.permissions.yaml"
    snapshot="${REPO}/${snapshot_rel}"
    upstream="${TMP}/${context}.permissions.yaml"
    label="${upstream_repo}@${REF}:${upstream_path}"
    endpoint="repos/${upstream_repo}/contents/${upstream_path}"

    if [ ! -f "${snapshot}" ]; then
        printf '%s：找不到快照 %s\n' "${context}" "${snapshot_rel}" >&2
        failed=1
        continue
    fi
    # 先確認上游路徑是檔案（目錄回 JSON 陣列，symlink、submodule 回其他 type），再取原始內容。
    # ref 用 -f 傳，由 gh 編碼成 query string；gh 在 HTTP 錯誤時 exit 非 0。
    kind="$(gh api --method GET "${endpoint}" -f ref="${REF}" \
        --jq 'if type == "object" then .type else "dir" end')" || kind=""
    if [ -z "${kind}" ]; then
        printf '%s：讀不到 %s\n' "${context}" "${label}" >&2
        failed=1
        continue
    elif [ "${kind}" != "file" ]; then
        printf '%s：%s 不是檔案（%s）\n' "${context}" "${label}" "${kind}" >&2
        failed=1
        continue
    fi
    if ! gh api --method GET -H "Accept: application/vnd.github.raw" "${endpoint}" -f ref="${REF}" > "${upstream}"; then
        printf '%s：讀不到 %s\n' "${context}" "${label}" >&2
        failed=1
        continue
    fi
    if [ ! -s "${upstream}" ]; then
        printf '%s：%s 是空的\n' "${context}" "${label}" >&2
        failed=1
        continue
    fi

    rc=0
    cmp -s "${upstream}" "${snapshot}" || rc=$?
    case "${rc}" in
        0)
            printf '%s：相同（%s）\n' "${context}" "${label}"
            ;;
        1)
            printf '%s：不同（- 上游、+ 快照）\n' "${context}"
            drc=0
            diff -u --label "${label}" --label "${snapshot_rel}" "${upstream}" "${snapshot}" || drc=$?
            if [ "${drc}" -eq 1 ]; then
                differ=1
            else
                # 0 表示 cmp 和 diff 結論不一致，其他值是 diff 本身出錯；兩者都不能下結論。
                printf '%s：diff 結果和 cmp 不一致或出錯（diff exit %s）\n' "${context}" "${drc}" >&2
                failed=1
            fi
            ;;
        *)
            printf '%s：比對失敗（cmp exit %s）\n' "${context}" "${rc}" >&2
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
