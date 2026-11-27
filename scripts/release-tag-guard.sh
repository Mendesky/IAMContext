#!/usr/bin/env bash
# release-docker.yml 的 guard：決定這次 tag push 要不要 build 並推 image。
#
# 用法（GitHub Actions 會帶這三個環境變數）：
#   GITHUB_SHA=<tag 指向的 commit> GITHUB_REF_NAME=<tag 名稱> GITHUB_OUTPUT=<輸出檔> bash scripts/release-tag-guard.sh
#
# 在 GITHUB_OUTPUT 寫一行 allowed=true 或 allowed=false，exit 0：
#   - tag 名稱要是版本號（1.2.3 或 1.2.3-beta.0 這類），否則 allowed=false（例如名為 latest 的 tag 不會推成 :latest）。
#   - tag 的 commit 要是 origin/main 或任一 origin/release/** 分支（release/ 底下任何名稱，含多層）的 ancestor，
#     否則 allowed=false（跳過，不 build、不 push、不 red-X）。
# 無法判斷時 exit 1（job 失敗）：repo 是 shallow、fetch 失敗、列不出 release 分支、merge-base 出錯。
# 出錯不能當成「不在分支上」而綠燈跳過。
#
# 這是發版流程的檢查，不是安全邊界：tag 觸發時跑的是 tag 那個 commit 上的 workflow 和這支腳本，能推分支和 tag 的人
# 改得到它們。release secrets 要靠 repo 設定保護（tag ruleset、release/* 分支保護、Environment 審核）。
#
# 測試：bash scripts/test-release-tag-guard.sh（拋棄式 bare repo，不連網路）。
set -euo pipefail

: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

allow() {
    echo "allowed=true" >> "$GITHUB_OUTPUT"
    echo "✅ ${GITHUB_REF_NAME} 在 $1 上，繼續 release"
    exit 0
}

skip() {
    echo "allowed=false" >> "$GITHUB_OUTPUT"
    echo "::notice::$1，跳過 release"
    exit 0
}

if ! [[ "$GITHUB_REF_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    skip "${GITHUB_REF_NAME} 不是版本號 tag（要像 1.2.3 或 1.2.3-beta.0）"
fi

# fetch-depth: 0 應該已經是完整歷史；self-hosted runner 重用的 workspace 若是 shallow，ancestor 判斷會誤判成「不在分支上」。
if [ "$(git rev-parse --is-shallow-repository)" != "false" ]; then
    echo "::error::repo 是 shallow，無法判斷 ancestor（checkout 要 fetch-depth: 0）" >&2
    exit 1
fi

# actions/checkout（fetch-depth: 0）已經把所有分支抓到 refs/remotes/origin/*。這裡再明確 fetch 一次 main 和 release/*，
# --prune 讓上游刪掉的 release 分支不再被當成允許的來源。允許的範圍只由下面比對的兩個前綴決定。
git fetch --quiet --prune origin \
    '+refs/heads/main:refs/remotes/origin/main' \
    '+refs/heads/release/*:refs/remotes/origin/release/*'

# merge-base --is-ancestor：0 = 是祖先，1 = 不是，其他 = 出錯。
is_ancestor() {
    local rc=0
    git merge-base --is-ancestor "$GITHUB_SHA" "$1" || rc=$?
    case "$rc" in
        0) return 0 ;;
        1) return 1 ;;
        *) echo "::error::無法判斷 ${GITHUB_SHA} 是否在 $1 上（git merge-base rc=${rc}）" >&2; exit 1 ;;
    esac
}

if is_ancestor refs/remotes/origin/main; then
    allow main
fi

# 先存成變數：for-each-ref 失敗時 set -e 讓 job 失敗，不會變成「沒有 release 分支」而綠燈跳過。
release_refs="$(git for-each-ref --format='%(refname)' 'refs/remotes/origin/release/')"
while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if is_ancestor "$ref"; then
        allow "${ref#refs/remotes/origin/}"
    fi
done <<< "$release_refs"

skip "${GITHUB_REF_NAME}（${GITHUB_SHA}）不在 main 或任何 release/ 分支上"
