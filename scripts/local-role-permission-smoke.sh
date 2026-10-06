#!/usr/bin/env bash
# 本機 API 驗收：角色、個人授予與移除、依事件順序重播的有效權限（對 localhost 的 IAM 發請求）。
# 每個情境建立自己的測試員工與角色（名稱 smoke-*-<時間戳>），彼此獨立，不碰既有員工資料。
# 輸出的「#n」對應驗收清單的情境編號。不涵蓋：#26 舊資料、#32 停掉 KurrentDB、#33 真實員工延遲，這三項請手動測。
# 用法：bash scripts/local-role-permission-smoke.sh
#   BASE 預設 http://localhost:24202；GRPC 預設 localhost:24203。
#   token 讀環境變數 IAM_ADMIN_API_TOKEN 與 IAM_GRPC_AUTH_TOKEN（~/.zshrc 已設定）。
# 相容 macOS 內建 bash 3.2：JSON 一律由 python 組好再傳；變數一律用 ${}；不用 set -u。
set -eo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${BASE:-http://localhost:24202}"
GRPC="${GRPC:-localhost:24203}"
TOKEN="${IAM_ADMIN_API_TOKEN:?請先設定 IAM_ADMIN_API_TOKEN}"
GRPC_TOKEN="${IAM_GRPC_AUTH_TOKEN:-}"
OP="local-smoke"
TS="$(date +%m%d-%H%M%S)"
DEPT="測試部-${TS}"
P1="StaffContext.Staff.GetStaffs"
P2="StaffContext.Staff.GetStaff"
P3="AuditContext.AuditContext.CreateBusinessClient"
BODY="$(mktemp)"
trap 'rm -f "${BODY}"' EXIT
PASS=0
FAIL=0
CODE=""
EA=""
U=""
ROLE=""

GRPCURL="$(command -v grpcurl || true)"
if [ -z "${GRPCURL}" ] && [ -x /opt/homebrew/bin/grpcurl ]; then GRPCURL=/opt/homebrew/bin/grpcurl; fi

# ---------- 小工具 ----------
ok()   { echo "  OK   ${1}"; PASS=$((PASS + 1)); }
bad()  { echo "  不符 ${1}"; FAIL=$((FAIL + 1)); }
pyj()  { python3 -c "${1}" "${@:2}"; }

call() {  # call <path> <json>：POST；狀態碼放 CODE，回應放 BODY 檔
  CODE="$(curl -s -o "${BODY}" -w '%{http_code}' -X POST "${BASE}${1}" \
    -H "Authorization: Bearer ${TOKEN}" -H "operatorId: ${OP}" \
    -H 'Content-Type: application/json' --data-binary "${2}")"
}
raw_call() {  # raw_call <path> <原始字串>：送未經檢查的 body
  CODE="$(curl -s -o "${BODY}" -w '%{http_code}' -X POST "${BASE}${1}" \
    -H "Authorization: Bearer ${TOKEN}" -H "operatorId: ${OP}" \
    -H 'Content-Type: application/json' --data-binary "${2}")"
}
get() { CODE="$(curl -s -o "${BODY}" -w '%{http_code}' "${BASE}${1}")"; }

check() {  # check <預期狀態碼> <說明> [預期錯誤碼]
  local err=""
  if [ -n "${3}" ]; then err="$(pyj 'import sys,json
try: print(json.load(open(sys.argv[1])).get("error",""))
except Exception: print("")' "${BODY}")"; fi
  if [ "${CODE}" = "${1}" ] && { [ -z "${3}" ] || [ "${err}" = "${3}" ]; }; then
    ok "${2} (HTTP ${CODE}${3:+ ${err}})"
  else
    bad "${2} (HTTP ${CODE}，預期 ${1}${3:+ ${3}}) 回應: $(cat "${BODY}")"
  fi
}

perms_of() {  # perms_of <userId> <說明> [預期權限...]
  local who="${1}" label="${2}"; shift 2; sleep 1
  local actual expected
  actual="$(curl -s "${BASE}/employee-access/permissions/${who}" | pyj 'import sys,json; print(" ".join(sorted(json.load(sys.stdin))))')"
  expected="$(pyj 'import sys; print(" ".join(sorted(sys.argv[1:])))' "$@")"
  if [ "${actual}" = "${expected}" ]; then ok "${label}: [${actual}]"; else bad "${label}: 實際 [${actual}]，預期 [${expected}]"; fi
}

holders() {  # holders <has|lacks> <permission> <userId> <說明> [department]
  sleep 1
  local q="permission=$(pyj 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${2}")"
  if [ -n "${5}" ]; then q="${q}&department=$(pyj 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${5}")"; fi
  if curl -s "${BASE}/employee-access/permission-holders?${q}" | pyj 'import sys,json; sys.exit(0 if sys.argv[1] in json.load(sys.stdin) else 1)' "${3}"; then
    if [ "${1}" = "has" ]; then ok "${4}"; else bad "${4}（不該出現卻出現）"; fi
  else
    if [ "${1}" = "lacks" ]; then ok "${4}"; else bad "${4}（該出現卻沒出現）"; fi
  fi
}

new_employee() {  # new_employee <說明> [userId]：設定 EA 與 U
  EA="$(uuidgen)"; U="${2:-$(uuidgen)}"
  call "/employee-access/${EA}/create-user-access-profile" "$(pyj 'import sys,json; print(json.dumps({"userId": sys.argv[1], "department": sys.argv[2], "jobTitle": "測試", "firm": "00000000"}))' "${U}" "${DEPT}")"
  if [ "${CODE}" = "200" ]; then echo "  ·    ${1}：employeeAccessId=${EA} userId=${U}"; else bad "建立測試員工 ${1} (HTTP ${CODE}) $(cat "${BODY}")"; fi
}
new_role() {  # new_role <標籤> [權限...]：設定 ROLE
  local tag="${1}"; shift
  call /roles "$(pyj 'import sys,json; print(json.dumps({"name": sys.argv[1]}))' "smoke-${tag}-${TS}")"
  if [ "${CODE}" != "200" ]; then bad "建立角色 ${tag} (HTTP ${CODE}) $(cat "${BODY}")"; ROLE=""; return; fi
  ROLE="$(pyj 'import sys,json; print(json.load(open(sys.argv[1]))["roleId"])' "${BODY}")"
  if [ "$#" -gt 0 ]; then role_add "${ROLE}" "$@"; [ "${CODE}" = "200" ] || bad "角色 ${tag} 加權限 (HTTP ${CODE})"; fi
}
role_add()    { local r="${1}"; shift; call "/roles/${r}/add-permissions"    "$(pyj 'import sys,json; print(json.dumps({"permissions": sys.argv[1:]}))' "$@")"; }
role_remove() { local r="${1}"; shift; call "/roles/${r}/remove-permissions" "$(pyj 'import sys,json; print(json.dumps({"permissions": sys.argv[1:]}))' "$@")"; }
user_json()   { pyj 'import sys,json; print(json.dumps({"userId": sys.argv[1], sys.argv[2]: sys.argv[3:]}))' "$@"; }
grant()        { local ea="${1}" u="${2}"; shift 2; call "/employee-access/${ea}/grant-privilege"  "$(user_json "${u}" permissions "$@")"; }
revoke_priv()  { local ea="${1}" u="${2}"; shift 2; call "/employee-access/${ea}/revoke-privilege" "$(user_json "${u}" permissions "$@")"; }
assign()       { local ea="${1}" u="${2}"; shift 2; call "/employee-access/${ea}/assign-roles"     "$(user_json "${u}" roles "$@")"; }
revoke_roles() { local ea="${1}" u="${2}"; shift 2; call "/employee-access/${ea}/revoke-roles"     "$(user_json "${u}" roles "$@")"; }

echo "IAM ${BASE}　gRPC ${GRPC}　測試部門 ${DEPT}"
echo "權限 P1=${P1}  P2=${P2}  P3=${P3}"

# ---------- 角色本身 ----------
echo; echo "角色本身（#1–#8）"
new_role R1; R1="${ROLE}"; [ -n "${R1}" ] && ok "#1 建立角色 (HTTP 200)"
call /roles "$(pyj 'import sys,json; print(json.dumps({"name": "   "}))')"; check 422 "#2 建立全空白名稱" roleNameRequired
call "/roles/${R1}/rename" "$(pyj 'import sys,json; print(json.dumps({"newName": "   "}))')"; check 422 "#2 改名成全空白" roleNameRequired
sleep 1
call /roles "$(pyj 'import sys,json; print(json.dumps({"name": sys.argv[1]}))' "smoke-R1-${TS}")"; check 422 "#3 建立同名角色（也證明 #2 的改名沒有生效）" roleNameDuplicated
call "/roles/${R1}/rename" "$(pyj 'import sys,json; print(json.dumps({"newName": sys.argv[1]}))' "smoke-R1b-${TS}")"; check 200 "#4 改名"
call "/roles/${R1}/rename" "$(pyj 'import sys,json; print(json.dumps({"newName": sys.argv[1]}))' "smoke-R1b-${TS}")"; check 422 "#4 改成相同名稱" roleNameUnchanged
call "/roles/${R1}/update-description" "$(pyj 'import sys,json; print(json.dumps({"newDescription": "smoke"}))')"; check 200 "#4 改描述"
call "/roles/${R1}/update-description" "$(pyj 'import sys,json; print(json.dumps({"newDescription": "smoke"}))')"; check 422 "#4 改成相同描述" descriptionUnchanged
role_add "${R1}" "No.Such.Permission"; check 422 "#5 加入不存在的權限" invalidPermission
role_add "${R1}" "${P1}"; check 200 "#6 加入 P1"
role_add "${R1}" "${P1}"; check 422 "#6 再加入 P1" permissionsUnchanged
role_remove "${R1}" "${P3}"; check 422 "#6 移除本來就沒有的 P3" permissionsUnchanged
new_role R9; R9="${ROLE}"
CODE="$(curl -s -o "${BODY}" -w '%{http_code}' -X DELETE "${BASE}/roles/${R9}" -H "Authorization: Bearer ${TOKEN}" -H "operatorId: ${OP}")"; check 200 "#7 刪除角色"
get "/roles/${R9}/permissions"; check 404 "#7 刪除後查權限"
sleep 1
get /roles
if pyj 'import sys,json
rows=json.load(open(sys.argv[1])); r=[x for x in rows if x["roleId"]==sys.argv[2]]
sys.exit(0 if r and sys.argv[3] in r[0].get("permissions",[]) and r[0]["name"]==sys.argv[4] else 1)' "${BODY}" "${R1}" "${P1}" "smoke-R1b-${TS}"; then
  ok "#8 GET /roles 帶 permissions，名稱為改名後的值"
else bad "#8 GET /roles 找不到 R1 的名稱或權限"; fi

# ---------- 指派與撤銷角色、個別移除 ----------
echo; echo "指派與撤銷角色、個別移除（#9–#12、#16）"
new_role A1 "${P1}" "${P2}"; A1="${ROLE}"
new_role A2 "${P2}"; A2="${ROLE}"
new_employee "E1"; E1EA="${EA}"; E1="${U}"
assign "${E1EA}" "${E1}" "$(uuidgen)"; check 422 "#9 指派不存在的角色" roleNotFound
assign "${E1EA}" "${E1}" "${A1}" "${A2}"; check 200 "#10 指派 A1、A2"
perms_of "${E1}" "#10 角色展開" "${P1}" "${P2}"
revoke_priv "${E1EA}" "${E1}" "${P1}"; check 200 "#16 個別移除只來自角色的 P1"
perms_of "${E1}" "#16 移除 P1 後" "${P2}"
revoke_roles "${E1EA}" "${E1}" "${A1}"; check 200 "#11 撤銷 A1（A2 也有 P2）"
perms_of "${E1}" "#11 重疊的 P2 保留" "${P2}"
new_role A3 "${P1}"; A3="${ROLE}"
new_employee "E2"; E2EA="${EA}"; E2="${U}"
grant "${E2EA}" "${E2}" "${P3}"; check 200 "#12 直接授予 P3"
assign "${E2EA}" "${E2}" "${A3}"; check 200 "#12 指派唯一角色 A3"
perms_of "${E2}" "#12 撤銷前" "${P1}" "${P3}"
revoke_roles "${E2EA}" "${E2}" "${A3}"; check 200 "#12 撤銷唯一角色"
perms_of "${E2}" "#12 角色權限消失，直接授予的 P3 不受影響" "${P3}"

# ---------- 角色變更傳到持有者 ----------
echo; echo "角色變更傳到持有者（#13–#15）"
new_role B4 "${P1}"; B4="${ROLE}"
new_role B5 "${P2}"; B5="${ROLE}"
new_employee "E3"; E3EA="${EA}"; E3="${U}"
new_employee "E4"; E4EA="${EA}"; E4="${U}"
assign "${E3EA}" "${E3}" "${B4}" "${B5}"; check 200 "指派 E3"
assign "${E4EA}" "${E4}" "${B4}" "${B5}"; check 200 "指派 E4"
role_add "${B4}" "${P3}"; check 200 "#13 B4 新增 P3"
perms_of "${E3}" "#13 E3 立刻有 P3" "${P1}" "${P2}" "${P3}"
perms_of "${E4}" "#13 E4 立刻有 P3" "${P1}" "${P2}" "${P3}"
role_add "${B5}" "${P1}"; check 200 "#14 B5 也加入 P1"
role_remove "${B4}" "${P1}"; check 200 "#14 B4 移除 P1"
perms_of "${E3}" "#14 B5 仍提供 P1" "${P1}" "${P2}" "${P3}"
role_add "${B4}" "${P2}"; check 200 "#15 B4 也加入 P2"
CODE="$(curl -s -o "${BODY}" -w '%{http_code}' -X DELETE "${BASE}/roles/${B5}" -H "Authorization: Bearer ${TOKEN}" -H "operatorId: ${OP}")"; check 200 "#15 刪除 B5"
perms_of "${E3}" "#15 只來自 B5 的 P1 消失，B4 也有的 P2 保留" "${P2}" "${P3}"
perms_of "${E4}" "#15 E4 同樣" "${P2}" "${P3}"

# ---------- 對個人的授予與移除 ----------
echo; echo "對個人的授予與移除（#17–#19）"
new_role C6 "${P2}"; C6="${ROLE}"
new_employee "E5"; E5EA="${EA}"; E5="${U}"
revoke_priv "${E5EA}" "${E5}" "${P3}"; check 422 "#17 移除完全沒有的權限" permissionNotExist
grant "${E5EA}" "${E5}" "${P1}"; check 200 "#18 直接授予 P1"
grant "${E5EA}" "${E5}" "${P1}"; check 422 "#18 再直接授予 P1" permissionAlreadyExists
assign "${E5EA}" "${E5}" "${C6}"; check 200 "#19 指派含 P2 的角色"
grant "${E5EA}" "${E5}" "${P2}"; check 200 "#19 直接授予只來自角色的 P2"
perms_of "${E5}" "#19 授予後" "${P1}" "${P2}"

# ---------- 直接授權與角色重疊 ----------
echo; echo "直接授權與角色重疊（#20–#21）"
new_role D7 "${P2}"; D7="${ROLE}"
new_employee "E6"; E6EA="${EA}"; E6="${U}"
assign "${E6EA}" "${E6}" "${D7}"; check 200 "指派 D7"
grant "${E6EA}" "${E6}" "${P3}"; check 200 "直接授予 P3"
role_add "${D7}" "${P3}"; check 200 "D7 也加入 P3"
perms_of "${E6}" "P3 同時來自直接授權與 D7" "${P2}" "${P3}"
role_remove "${D7}" "${P3}"; check 200 "#20 D7 移除 P3"
perms_of "${E6}" "#20 直接授予的 P3 一起消失" "${P2}"
grant "${E6EA}" "${E6}" "${P3}"; check 200 "#21 再直接授予 P3"
perms_of "${E6}" "#21 P3 回來" "${P2}" "${P3}"

# ---------- 最新的事件說了算 ----------
echo; echo "最新的事件說了算（#22–#24）"
new_role F8 "${P1}"; F8="${ROLE}"
new_employee "E7"; E7EA="${EA}"; E7="${U}"
assign "${E7EA}" "${E7}" "${F8}"; check 200 "指派 F8"
revoke_priv "${E7EA}" "${E7}" "${P1}"; check 200 "個別移除 P1"
perms_of "${E7}" "移除後"
revoke_roles "${E7EA}" "${E7}" "${F8}"; check 200 "撤銷 F8"
assign "${E7EA}" "${E7}" "${F8}"; check 200 "重新指派 F8"
perms_of "${E7}" "#22 重新指派後 P1 回來" "${P1}"
new_role F9 "${P2}"; F9="${ROLE}"
new_employee "E8"; E8EA="${EA}"; E8="${U}"
assign "${E8EA}" "${E8}" "${F9}"; check 200 "指派 F9"
revoke_priv "${E8EA}" "${E8}" "${P2}"; check 200 "個別移除 P2"
role_remove "${F9}" "${P2}"; check 200 "F9 移除 P2"
role_add "${F9}" "${P2}"; check 200 "F9 加回 P2"
perms_of "${E8}" "#23 角色加回後 P2 回來" "${P2}"
new_role F10 "${P1}"; F10="${ROLE}"
new_employee "E9"; E9EA="${EA}"; E9="${U}"
grant "${E9EA}" "${E9}" "${P3}"; check 200 "直接授予 P3"
revoke_priv "${E9EA}" "${E9}" "${P3}"; check 200 "收回直接授予的 P3"
assign "${E9EA}" "${E9}" "${F10}"; check 200 "指派 F10"
role_add "${F10}" "${P3}"; check 200 "F10 之後才加入 P3"
perms_of "${E9}" "#24 員工擁有 P3" "${P1}" "${P3}"

# ---------- 建檔與舊資料 ----------
echo; echo "同一位員工建檔兩次（#25）"
new_employee "E10 第一次建檔"; E10A="${EA}"; E10="${U}"
grant "${E10A}" "${E10}" "${P1}"; check 200 "第一次建檔後授予 P1"
perms_of "${E10}" "第二次建檔前" "${P1}"
new_employee "E10 第二次建檔（同一個 userId）" "${E10}"; E10B="${EA}"
perms_of "${E10}" "#25 第二次建檔重設起點，P1 不再有效"
grant "${E10B}" "${E10}" "${P2}"; check 200 "第二次建檔後授予 P2"
perms_of "${E10}" "#25 只有第二次建檔之後的權限" "${P2}"

# ---------- 反查與兩個入口 ----------
echo; echo "反查與兩個入口（#27–#30）"
holders has "${P2}" "${E1}" "#27 只透過角色持有 P2 的 E1 會被列出"
holders lacks "${P1}" "${E1}" "#28 個別移除 P1 的 E1 不會被列出"
holders lacks "${P1}" "${E3}" "#28 角色已不再提供 P1 的 E3 不會被列出"
holders has "${P2}" "${E1}" "#29 department 過濾：本次測試部門列出 E1" "${DEPT}"
holders lacks "${P2}" "${E1}" "#29 department 過濾：其他部門不列出 E1" "不存在的部門-${TS}"
if [ -z "${GRPCURL}" ]; then
  echo "  略過 #30：找不到 grpcurl"
elif [ -z "${GRPC_TOKEN}" ]; then
  echo "  略過 #30：沒有設定 IAM_GRPC_AUTH_TOKEN"
else
  for who in "${E1}" "${E3}" "${E9}"; do
    g="$("${GRPCURL}" -plaintext -import-path "${REPO}/proto" -proto PermissionsService.proto \
      -H "authorization: Bearer ${GRPC_TOKEN}" -d "$(pyj 'import sys,json; print(json.dumps({"user_id": sys.argv[1]}))' "${who}")" \
      "${GRPC}" IAMContext.PermissionsService/GetPermissions 2>&1 | pyj 'import sys,json
try: print(" ".join(sorted(json.load(sys.stdin).get("permissions",[]))))
except Exception: print("ERROR")')"
    h="$(curl -s "${BASE}/employee-access/permissions/${who}" | pyj 'import sys,json; print(" ".join(sorted(json.load(sys.stdin))))')"
    if [ "${g}" = "${h}" ]; then ok "#30 gRPC 與 HTTP 相同 (${who:0:8}…): [${g}]"; else bad "#30 gRPC [${g}] 與 HTTP [${h}] 不同 (${who})"; fi
  done
fi

# ---------- 錯誤與穩定性 ----------
echo; echo "錯誤與穩定性（#31）"
raw_call /roles '{"name":"x",'; check 500 "#31 body 不是合法 JSON"
raw_call /roles '{}'; check 500 "#31 缺必填欄位"

echo
echo "通過 ${PASS} 項，不符 ${FAIL} 項。未涵蓋、請手動測：#26 舊資料、#32 停掉 KurrentDB、#33 真實員工延遲。"
echo "本次建立的角色與員工名稱都帶 ${TS}，可保留或自行刪除。"
[ "${FAIL}" = "0" ] || exit 1
