#!/usr/bin/env python3
"""依現有 AllocateFor<所> 持有者，一對一授予 AllocateTo<所>（規格 2026-10-28 §E.1、T2）。

預設 dry-run：只列出「會動什麼」，不寫入。要寫入必須明確加 --apply。
可重跑：已持有者不會再授予；重複授予視為已完成（角色：permissionsUnchanged 或 permissionAlreadyExists；
直接授予：permissionAlreadyExists）。
手寫腳本（不是 Genesis 產物）。只用 Python 3 標準函式庫，macOS 內建 python3 即可。

做法（每個所 X）：
  1. 角色：GET /roles 取所有角色，含 AllocateFor<X> 的角色 -> POST /roles/{id}/add-permissions AllocateTo<X>
  2. 直接授予：permission-holders(AllocateFor<X>) 扣掉 permission-holders(AllocateTo<X>)
     （dry-run 另扣掉「即將被角色帶到」的人）-> POST /employee-access/{eaId}/grant-privilege
     employeeAccessId 沒有 HTTP 反查端點，需用 --ea-map 提供 userId -> employeeAccessId 對照
     （做法見 docs 旁的 batch2-iam-grant-runbook.md）。查不到對照的人會列為「無法授予」，結束碼 1。
  3. 驗收：holders(AllocateTo<X>) 必須涵蓋 holders(AllocateFor<X>)。

連線與認證（不寫死任何主機或 token）：
  --base URL 或環境變數 IAM_BASE        IAM HTTP 位址（必填，例如本機 http://localhost:24202）
  環境變數 IAM_ADMIN_API_TOKEN（或 IAM_TOKEN）  Bearer token；--apply 時必填，dry-run 有設才帶
  --operator 或 IAM_OPERATOR_ID          operatorId header，預設 grant-allocate-to-script

用法：
  python3 scripts/grant-allocate-to.py --base http://localhost:24202                 # dry-run
  python3 scripts/grant-allocate-to.py --base ... --ea-map map.json --apply          # 寫入
  python3 scripts/grant-allocate-to.py --base ... --firm Taipei --firm Main          # 只處理部分所
結束碼：0 完成；1 有無法授予的人／驗收不過／部分請求失敗；2 參數或連線錯誤。
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PREFIX = "OpportunityContext.Handover."
# IAM 對「權限已存在」的回應：角色的 add-permissions 回 permissionsUnchanged（Role+AddPermissions：差集為空），
# 直接授予的 grant-privilege 回 permissionAlreadyExists（EmployeeAccess+GrantPrivilege）；都是 422。
# dry-run 之後若有人先更新了角色，apply 時會碰到，兩種都當成「已授權、略過」。
ROLE_ALREADY_GRANTED = ("permissionsUnchanged", "permissionAlreadyExists")
DIRECT_ALREADY_GRANTED = ("permissionAlreadyExists",)
FIRMS = ["Main", "Taipei", "Taoyuan", "Taichung", "Changhua", "Chiayi"]  # 康達、捷達優不建（D-3）


class Fatal(Exception):
    pass


class Client:
    def __init__(self, base, token, operator, timeout):
        self.base = base.rstrip("/")
        self.token = token
        self.operator = operator
        self.timeout = timeout

    def request(self, method, path, body=None):
        """回傳 (status, parsed_json_or_None)。連不上丟 Fatal。"""
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("operatorId", self.operator)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", "Bearer " + self.token)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as e:
            status, raw = e.code, e.read()
        except (urllib.error.URLError, OSError) as e:
            raise Fatal("連不上 %s（%s）" % (self.base, getattr(e, "reason", e)))
        try:
            return status, json.loads(raw.decode("utf-8")) if raw else None
        except ValueError:
            return status, None

    def get_list(self, path):
        status, js = self.request("GET", path)
        if status != 200 or not isinstance(js, list):
            raise Fatal("GET %s 回 HTTP %s" % (path, status))
        return js

    def holders(self, permission):
        q = urllib.parse.urlencode({"permission": permission})
        return set(self.get_list("/employee-access/permission-holders?" + q))

    def role_holders(self, role_id):
        q = urllib.parse.urlencode({"role": role_id})
        return set(self.get_list("/employee-access/role-holders?" + q))


def load_ea_map(path):
    """支援 JSON 物件 {userId: eaId}，或每行 'userId eaId' / 'userId,eaId'（# 開頭為註解）。"""
    if not path:
        return {}
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        raise Fatal("讀不到 --ea-map：%s" % e)
    stripped = text.lstrip()
    if stripped.startswith("{"):
        try:
            obj = json.loads(text)
        except ValueError as e:
            raise Fatal("--ea-map 不是合法 JSON：%s" % e)
        return {str(k): str(v) for k, v in obj.items()}
    result = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.replace(",", " ").split()
        if len(parts) != 2:
            raise Fatal("--ea-map 格式錯誤（要兩欄）：%r" % line)
        result[parts[0]] = parts[1]
    return result


def plan_firm(client, firm):
    for_p, to_p = PREFIX + "AllocateFor" + firm, PREFIX + "AllocateTo" + firm
    roles = client.get_list("/roles")
    role_rows = []
    for r in roles:
        perms = r.get("permissions") or []
        if for_p in perms:
            ids = client.role_holders(r["roleId"])
            role_rows.append({
                "roleId": r["roleId"], "name": r.get("name", ""),
                "alreadyHasTo": to_p in perms,
                "holders": len(ids), "holderIds": ids,
            })
    for_h, to_h = client.holders(for_p), client.holders(to_p)
    via_role = set()
    for r in role_rows:
        if not r["alreadyHasTo"]:
            via_role |= r["holderIds"]
    return {
        "firm": firm, "forPerm": for_p, "toPerm": to_p,
        "roles": role_rows,
        "roleTodo": [r for r in role_rows if not r["alreadyHasTo"]],
        "forHolders": for_h,
        "direct": sorted(for_h - to_h - via_role),
    }


def main():
    ap = argparse.ArgumentParser(description="依 AllocateFor<所> 持有者一對一授予 AllocateTo<所>（預設 dry-run）",
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog="說明見檔案開頭註解與 docs/specs/batch2-iam-grant-runbook.md")
    ap.add_argument("--base", default=os.environ.get("IAM_BASE"), help="IAM HTTP 位址（或環境變數 IAM_BASE）")
    ap.add_argument("--operator", default=os.environ.get("IAM_OPERATOR_ID", "grant-allocate-to-script"))
    ap.add_argument("--apply", action="store_true", help="真的寫入（沒有這個旗標一律 dry-run）")
    ap.add_argument("--ea-map", help="userId -> employeeAccessId 對照檔（JSON 物件或每行兩欄）")
    ap.add_argument("--firm", action="append", choices=FIRMS, help="只處理指定的所（可重複）；預設六個所全做")
    ap.add_argument("--settle", type=float, default=3.0, help="寫入角色後等投影的秒數（預設 3）")
    ap.add_argument("--timeout", type=float, default=15.0, help="單一請求逾時秒數（預設 15）")
    args = ap.parse_args()

    if not args.base:
        print("缺 --base（或 IAM_BASE）：請指定 IAM HTTP 位址", file=sys.stderr)
        return 2
    token = os.environ.get("IAM_ADMIN_API_TOKEN") or os.environ.get("IAM_TOKEN")
    if args.apply and not token:
        print("--apply 需要環境變數 IAM_ADMIN_API_TOKEN（或 IAM_TOKEN）", file=sys.stderr)
        return 2

    client = Client(args.base, token, args.operator, args.timeout)
    firms = args.firm or FIRMS
    mode = "APPLY（會寫入）" if args.apply else "DRY-RUN（不寫入）"
    print("模式：%s  目標：%s  所：%s" % (mode, client.base, ",".join(firms)))

    try:
        ea_map = load_ea_map(args.ea_map)
        plans = [plan_firm(client, f) for f in firms]
    except Fatal as e:
        print("錯誤：%s" % e, file=sys.stderr)
        return 2

    problems = 0
    for p in plans:
        print("\n== %s ==  持有 %s：%d 人" % (p["firm"], "AllocateFor" + p["firm"], len(p["forHolders"])))
        for r in p["roles"]:
            tag = "已含 AllocateTo，略過" if r["alreadyHasTo"] else "待加入 AllocateTo"
            print("  角色 %s（%s）持有人 %d：%s" % (r["name"], r["roleId"], r["holders"], tag))
        if not p["roles"]:
            print("  （沒有角色含 AllocateFor%s）" % p["firm"])
        print("  直接授予 %d 人" % len(p["direct"]))
        for u in p["direct"]:
            print("    userId=%s employeeAccessId=%s" % (u, ea_map.get(u, "<無對照>")))
    if not args.apply:
        unresolved = sum(1 for p in plans for u in p["direct"] if u not in ea_map)
        print("\nDRY-RUN 結束，未寫入任何資料。要寫入請加 --apply。")
        if unresolved:
            print("注意：%d 位要直接授予的人沒有 employeeAccessId 對照，apply 時會列為無法授予（提供 --ea-map）。" % unresolved)
        return 0

    # ---- apply ----
    try:
        for p in plans:
            for r in p["roleTodo"]:
                status, js = client.request("POST", "/roles/%s/add-permissions" % r["roleId"],
                                            {"permissions": [p["toPerm"]]})
                err = js.get("error") if isinstance(js, dict) else None
                if status == 200:
                    print("[角色] %s 加入 %s：OK" % (r["name"], p["toPerm"]))
                elif status == 422 and err in ROLE_ALREADY_GRANTED:
                    print("[角色] %s 已有 %s：視為完成" % (r["name"], p["toPerm"]))
                else:
                    print("[角色] %s 加入 %s 失敗：HTTP %s %s" % (r["name"], p["toPerm"], status, err))
                    problems += 1
        if any(p["roleTodo"] for p in plans):
            time.sleep(args.settle)
        for p in plans:
            # 角色寫入後重算：已被角色帶到的人不必再直接授予
            todo = sorted(client.holders(p["forPerm"]) - client.holders(p["toPerm"]))
            for u in todo:
                ea = ea_map.get(u)
                if not ea:
                    print("[直接] userId=%s（%s）無法授予：--ea-map 沒有對照" % (u, p["firm"]))
                    problems += 1
                    continue
                status, js = client.request("POST", "/employee-access/%s/grant-privilege" % ea,
                                            {"userId": u, "permissions": [p["toPerm"]]})
                err = js.get("error") if isinstance(js, dict) else None
                if status == 200:
                    print("[直接] userId=%s 授予 %s：OK" % (u, p["toPerm"]))
                elif status == 422 and err in DIRECT_ALREADY_GRANTED:
                    print("[直接] userId=%s 已有 %s：視為完成" % (u, p["toPerm"]))
                else:
                    print("[直接] userId=%s 授予 %s 失敗：HTTP %s %s" % (u, p["toPerm"], status, err))
                    problems += 1
        time.sleep(args.settle)
        print("\n== 驗收：holders(AllocateTo) 須涵蓋 holders(AllocateFor) ==")
        for p in plans:
            for_h, to_h = client.holders(p["forPerm"]), client.holders(p["toPerm"])
            missing = sorted(for_h - to_h)
            print("  %s：For=%d To=%d 缺少=%d %s" % (p["firm"], len(for_h), len(to_h), len(missing),
                                                  "PASS" if not missing else "FAIL " + ",".join(missing)))
            if missing:
                problems += 1
    except Fatal as e:
        print("錯誤：%s" % e, file=sys.stderr)
        return 2
    print("\n完成，問題數：%d" % problems)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
