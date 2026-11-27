#!/usr/bin/env bash
# scripts/release-tag-guard.sh 的測試：在暫存目錄建一個拋棄式 bare repo 當 origin，不連網路、不碰任何環境。
# 用法：bash scripts/test-release-tag-guard.sh   （全部通過 exit 0，否則 exit 1）
set -euo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/release-tag-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0

g() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@"; }

g init -q --bare "$TMP/origin.git"
g clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work"
commit() { g commit -q --allow-empty -m "$1"; git rev-parse HEAD; }
BASE=$(commit base); g push -q origin HEAD:main
g checkout -q -b r "$BASE";  REL=$(commit rel);       g push -q origin HEAD:release/1.10.x
g checkout -q -b n "$BASE";  NESTED=$(commit nested); g push -q origin HEAD:release/team/x
g checkout -q -b f "$BASE";  FEAT=$(commit feat);     g push -q origin HEAD:feature/x
g checkout -q -b s "$BASE";  RELS=$(commit relish);   g push -q origin HEAD:releases/y
g clone -q "$TMP/origin.git" "$TMP/runner" 2>/dev/null

# expect <name> <sha> <tag> <expected exit> <expected output line or "">
expect() {
    local name=$1 sha=$2 tag=$3 want_rc=$4 want_out=$5 out rc=0
    out="$TMP/out.$name"; : > "$out"
    (cd "$TMP/runner" && GITHUB_SHA=$sha GITHUB_REF_NAME=$tag GITHUB_OUTPUT=$out bash "$GUARD") > "$TMP/log.$name" 2>&1 || rc=$?
    local got; got="$(cat "$out")"
    if [ "$rc" = "$want_rc" ] && [ "$got" = "$want_out" ]; then
        echo "ok   $name (rc=$rc, ${got:-no output})"
    else
        echo "FAIL $name: want rc=$want_rc '${want_out}', got rc=$rc '${got}'"; sed 's/^/     /' "$TMP/log.$name"
        fails=$((fails + 1))
    fi
}

expect main          "$BASE"   1.2.3          0 allowed=true
expect release       "$REL"    1.11.0-beta.2  0 allowed=true
expect nested        "$NESTED" 1.2.3-rc.1     0 allowed=true
expect feature       "$FEAT"   1.2.3          0 allowed=false
expect releases      "$RELS"   1.2.3          0 allowed=false
expect latest-name   "$BASE"   latest         0 allowed=false
expect v-prefix      "$BASE"   v1.2.3         0 allowed=false
expect bogus-sha     0000000000000000000000000000000000000000 1.2.3 1 ""

g -C "$TMP/work" push -q origin :release/1.10.x
expect deleted-release "$REL" 1.11.0-beta.2 0 allowed=false

g clone -q --depth 1 "file://$TMP/origin.git" "$TMP/shallow" 2>/dev/null
out="$TMP/out.shallow"; : > "$out"; rc=0
(cd "$TMP/shallow" && GITHUB_SHA=$BASE GITHUB_REF_NAME=1.2.3 GITHUB_OUTPUT=$out bash "$GUARD") > "$TMP/log.shallow" 2>&1 || rc=$?
if [ "$rc" = 1 ] && [ ! -s "$out" ]; then echo "ok   shallow (rc=1)"; else echo "FAIL shallow: rc=$rc out='$(cat "$out")'"; fails=$((fails + 1)); fi

echo "fails=$fails"
[ "$fails" = 0 ]
