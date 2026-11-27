#!/usr/bin/env bash
# scripts/release-tag-guard.sh 的測試：在暫存目錄建一個拋棄式 bare repo 當 origin，不連網路、不碰任何環境，
# 也不讀使用者的 git 設定。另外靜態檢查 release-docker.yml 用了這支 guard、不推 latest。
# 用法：bash scripts/test-release-tag-guard.sh   （全部通過 exit 0，否則 exit 1）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/release-tag-guard.sh"
WORKFLOW="$ROOT/.github/workflows/release-docker.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

# 從 hook 或 rebase --exec 裡跑時，外層的 GIT_* 不能漏進來；使用者的全域設定（gpgsign、hooks）也不能。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# git 2.32 以前不認 GIT_CONFIG_GLOBAL：HOME 也換成空目錄。
mkdir -p "$TMP/home"; export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config"
g() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }

g init -q --bare "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work"
commit() { g commit -q --allow-empty -m "$1"; git rev-parse HEAD; }
BASE=$(commit base)
# release/1.10.x 從 BASE 開出；main 之後再往前走，所以 MAINONLY 只在 main 上（不在任何 release/ 分支上）。
g checkout -q -b r "$BASE";  REL=$(commit rel);       g push -q origin HEAD:release/1.10.x
g checkout -q -b n "$BASE";  NESTED=$(commit nested); g push -q origin HEAD:release/team/x
g checkout -q -b f "$BASE";  FEAT=$(commit feat);     g push -q origin HEAD:feature/x
g checkout -q -b s "$BASE";  RELS=$(commit relish);   g push -q origin HEAD:releases/y
g checkout -q -b m "$BASE";  MAINONLY=$(commit main-only); g push -q origin HEAD:main
g clone -q "$TMP/origin.git" "$TMP/runner" 2>/dev/null

# expect <name> <sha> <tag> <expected exit> <expected GITHUB_OUTPUT> [text the log must contain]
expect() {
    local name=$1 sha=$2 tag=$3 want_rc=$4 want_out=$5 want_log=${6:-} dir=${7:-$TMP/runner} rc=0
    local out="$TMP/out.$name" log="$TMP/log.$name"
    : > "$out"
    (cd "$dir" && GITHUB_SHA=$sha GITHUB_REF_NAME=$tag GITHUB_OUTPUT=$out bash "$GUARD") > "$log" 2>&1 || rc=$?
    local got; got="$(cat "$out")"
    if [ "$rc" = "$want_rc" ] && [ "$got" = "$want_out" ] && { [ -z "$want_log" ] || grep -qF -- "$want_log" "$log"; }; then
        echo "ok   $name (rc=$rc, ${got:-no output})"
    else
        echo "FAIL $name: want rc=$want_rc '${want_out}' log~'${want_log}', got rc=$rc '${got}'"; sed 's/^/     /' "$log"
        fails=$((fails + 1))
    fi
}

expect main-only     "$MAINONLY" 1.2.3          0 allowed=true "在 main 上"
expect release       "$REL"      1.11.0-beta.2  0 allowed=true "在 release/1.10.x 上"
expect release-base  "$BASE"     1.10.0         0 allowed=true
expect nested        "$NESTED"   1.2.3-rc.1     0 allowed=true "在 release/team/x 上"
expect feature       "$FEAT"     1.2.3          1 ""           "不在 main 或任何 release/ 分支上"
expect releases      "$RELS"     1.2.3          1 ""           "不在 main 或任何 release/ 分支上"
expect latest-name   "$MAINONLY" latest         0 allowed=false "不是版本號 tag"
expect v-prefix      "$MAINONLY" v1.2.3         0 allowed=false "不是版本號 tag"
expect leading-zero  "$MAINONLY" 01.2.3         0 allowed=false "不是版本號 tag"
expect trailing-dash "$MAINONLY" 1.2.3-         0 allowed=false "不是版本號 tag"
expect uppercase     "$MAINONLY" 1.2.3-RC1      0 allowed=false "不是版本號 tag"
expect too-long      "$MAINONLY" "1.2.3-$(printf 'a%.0s' $(seq 1 123))" 0 allowed=false "不是版本號 tag"
expect max-length    "$MAINONLY" "1.2.3-$(printf 'a%.0s' $(seq 1 122))" 0 allowed=true
expect missing-sha   1111111111111111111111111111111111111111 1.2.3 1 "" "merge-base rc=128"

# runner clone 之後才出現或往前走的 release 分支：guard 自己的 fetch 要抓到。
cd "$TMP/work"
g checkout -q -b late "$BASE"; LATE=$(commit late); g push -q origin HEAD:release/late
g checkout -q r; REL2=$(commit rel2); g push -q origin HEAD:release/1.10.x
expect new-branch    "$LATE"     1.2.4-beta.0   0 allowed=true "在 release/late 上"
expect moved-branch  "$REL2"     1.11.0-beta.3  0 allowed=true "在 release/1.10.x 上"

# 上游刪掉的 release 分支不再放行（--prune）。
g push -q origin :release/1.10.x
expect deleted-release "$REL2"   1.11.0-beta.3  1 ""           "不在 main 或任何 release/ 分支上"

# shallow repo、fetch 失敗：job 失敗，不寫 output。
g clone -q --depth 1 "file://$TMP/origin.git" "$TMP/shallow" 2>/dev/null
expect shallow       "$MAINONLY" 1.2.3          1 ""           "shallow" "$TMP/shallow"
g clone -q "$TMP/origin.git" "$TMP/nofetch" 2>/dev/null
git -C "$TMP/nofetch" remote set-url origin "$TMP/does-not-exist.git"
expect fetch-fails   "$MAINONLY" 1.2.3          1 ""           "fetch origin" "$TMP/nofetch"

# check-image-tags.sh：只有 <IMAGE>:<tag> 一個時才過。
tags_case() {
    local name=$1 want_rc=$2 tags=$3 rc=0
    TAGS="$tags" WANT="img:1.2.3" bash "$ROOT/scripts/check-image-tags.sh" > "$TMP/log.tags.$name" 2>&1 || rc=$?
    if [ "$rc" = "$want_rc" ]; then echo "ok   image-tags $name (rc=$rc)"; else echo "FAIL image-tags $name: want rc=$want_rc got rc=$rc"; fails=$((fails + 1)); fi
}
tags_case exact          0 "img:1.2.3"
tags_case trailing-blank 0 "$(printf 'img:1.2.3\n\n')"
tags_case with-latest    1 "$(printf 'img:1.2.3\nimg:latest')"
tags_case only-latest    1 "img:latest"
tags_case lowercased     1 "img:1.2.3-rc1"
tags_case empty          1 ""

# release-docker.yml：guard 用這支腳本、兩個 job 都固定 commit、build 要 allowed、push 前檢查 tag、不推 latest。
# 註解行不算（不然寫在註解裡的字會讓檢查過關）。
code="$TMP/workflow.code"; grep -vE '^[[:space:]]*#' "$WORKFLOW" > "$code"
count() { grep -cE -- "$1" "$code" || true; }
rule() { if [ "$2" = "$3" ]; then echo "ok   workflow $1"; else echo "FAIL workflow $1: want $3, got $2"; fails=$((fails + 1)); fi; }
rule "guard runs release-tag-guard.sh"        "$(count '^ +run: bash scripts/release-tag-guard.sh$')" 1
rule "push checks image tags"                 "$(count '^ +run: bash scripts/check-image-tags.sh$')" 1
rule "both checkouts pinned to github.sha"    "$(count '^ +ref: \$\{\{ github.sha \}\}')" 2
rule "build needs allowed"                    "$(count "needs.guard.outputs.allowed == 'true'")" 1
rule "latest=false"                           "$(count '^ +latest=false$')" 1
rule "no other latest"                        "$(count 'latest' | tr -d ' ')" 1

echo "fails=$fails"
[ "$fails" = 0 ]
