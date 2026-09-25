# 所別格式統一（統編）＋ 授權範圍判斷端點（scope-check）

## 來源

討論：2026-09-03 對話（無獨立 discussion MD）。起因為實機事故——案件分配到「審1」後，該部門具權限的 6 位同仁完全看不到案件。追查後確認是所別格式不一致造成 IAM 反查回空。

本 task 是 `OpportunityContext/docs/tasks/2026-09-03-edit-department.md` 的**前置**，必須先完成。

---

## 目標

系統中「所別（firm）」有兩種表示法且混用：**統編**（`88183980`）與**名稱**（`台北市所`）。OC 的 `DepartmentAssigned` 事件帶統編、IAM 存名稱，兩者以字串完全相等比對 → **永遠零命中**，且失敗是靜默的（只 log 一行就 return），前端顯示「分配成功」但實際上沒有任何人被加入案件。

同時，「某人是否屬於某所某組」這個判斷目前散落在兩處資料源（IAM 的 `department`/`firm` 欄位、StaffContext 的員工名冊），沒有同步機制，且未來會有更多呼叫端。

本 task 做兩件事：
1. **統一所別格式為統編**，以 `StaffContext` 的 `Firm` enum rawValue 為準
2. **IAM 新增「授權範圍判斷」端點**，讓所有權限/歸屬相關的範圍判斷有唯一入口

### 為何選統編

- 統編是 `Sources/StaffAggregate/Entity/WorkUnit.swift:13-20` 的 `Firm` enum rawValue，由程式碼強制，**具唯一性保證**
- 名稱沒有唯一性：實測 55 環境的 IAM 同時存在 `台北市所` 與 `台北所` 兩種寫法（同一個所），另在 mendesky-platform-console 測試資料中還出現 `台北事務所`
- OC 的事件、StaffContext 的 API 參數（`firmBusinessId`）本來就用統編 → **只有 IAM 需要改**

### 為何 scope-check 不做成「查某人部門」

避免與 StaffContext 的名冊查詢功能重疊造成長期混淆。職責切分：

| | 回答的問題 | 使用時機 |
|---|---|---|
| StaffContext | 「這個組有哪些員工」「這個人叫什麼」 | 顯示名單、選人下拉、人事類 UI |
| **IAM scope-check** | 「這些人是否在這個授權範圍內」 | **所有權限/歸屬判斷** |

規則：**要拿來做判斷的問 IAM，要拿來顯示的問 StaffContext。**

端點只回傳判斷結果、不回傳部門屬性 —— 這樣沒有人能把 IAM 當通訊錄用，也保留了未來「IAM 不再持有組織欄位」的退路（屆時只改實作，呼叫端不動）。

---

## 介面合約（Interface Contract）

### 1. `firm` 欄位語意變更（IAM）

`EmployeeAccess.firm`（`Sources/EmployeeAccessAggregate/Entity/EmployeeAccess.swift:15`）的值改為**統編字串**，值域對齊 StaffContext `Firm` enum：

| 統編 | 所別 |
|---|---|
| `01020314` | 總所 |
| `88183980` | 台北所 |
| `41171816` | 桃園所 |
| `47575385` | 台中所 |
| `82576039` | 彰化所 |
| `47779732` | 嘉義所 |

- 型別維持 `String?`（不改成 enum —— IAM 不該綁死 StaffContext 的值域，未來新增所別時 IAM 不需改 code）
- openapi 的 `firm` 參數與欄位補 description：「所別統一編號（統編），值域見 StaffContext `Firm`」
- **不做格式驗證**：IAM 不驗證傳入值是否為合法統編（保持寬鬆，錯誤值自然查無資料）[決策：避免 IAM 需要跟著 StaffContext 的值域更新]

### 2. `POST /employee-access/scope-check`（新增端點）

```
operationId: checkScope
headers: operatorId
body:
  userIds:    [String]   # 要判斷的對象，1..N
  firm:       String?    # 統編；nil = 不以所別限縮
  department: String?    # nil = 不以部門限縮
response 200:
  inScope:    [String]   # userIds 之中，屬於該範圍者（順序不保證，去重）
```

- **語意**：回傳 `userIds` 與「該範圍成員」的交集。`firm` 與 `department` 皆為 nil → 回傳所有**存在於 IAM 且狀態有效**的 userId [inferred：需確認 `EmployeeStatus` 是否要納入判斷，見「已知限制」]
- **不存在於 IAM 的 userId**：視為不在範圍內，**靜默排除**（不報錯）—— 呼叫端可用「回傳少了誰」推知
- **空輸入**：`userIds` 為空 → 回 `{ inScope: [] }`，200
- **不回傳部門/所別屬性**：這是刻意的，見上方「為何 scope-check 不做成查某人部門」
- 錯誤：503（讀模型不可用）；不需要 admin token（與 `getPermissions` / `getPermissionHolders` 同層，屬查詢類）[需確認：與現行 `AdminTokenMiddleware` 的守備範圍一致]

### 3. 既有端點的相容性

- `getPermissionHolders(permission, firm?, department?)` 的 `firm` 參數語意同步改為統編。**呼叫端不需改 code**（OC 本來就傳統編，改完才會開始正常運作）
- 不移除 `firm`/`department` 過濾參數（是否移除屬「IAM 該不該持有組織欄位」的更大議題，另案討論）

---

## 改動檔案

| 檔案 | 改動描述 |
|---|---|
| `Sources/EmployeeAccessAggregate/openapi.yaml` | 新增 `POST /employee-access/scope-check`；`firm` 參數/欄位 description 改為統編語意 |
| `Sources/EmployeeAccessAggregate/Adapter/ApiHandler.swift` | 新增 `checkScope` handler |
| `Sources/EmployeeAccessAggregate/Adapter/CheckScope/…` | **新增**：ApplicationService（比照 `GetPermissionHolders/` 的結構，重用其 department/firm 比對邏輯） |
| `scripts/migrations/…（新檔）` | **新增**：一次性遷移腳本，把既有 EmployeeAccess 的 firm 從名稱轉統編 |
| `Tests/…/CheckScopeTests.swift` | **新增** |

**受影響但不改 code 的呼叫端**（改完後行為會從「壞的」變成「正常」，需回歸驗證）：
- `OpportunityContext/Sources/OpportunityContext/Listener/WhenHandoverDepartmentAssigned.swift:53`
- `OpportunityContext/Sources/OpportunityContext/Listener/WhenHandoverDepartmentAssignedForAnnotating.swift:128`
- `mendesky-platform-console`（IAM 管理介面，顯示所別處需確認是否顯示統編 → 應改為顯示名稱，對照表在前端）

---

## 實作步驟

### Step 1 — 盤點既有資料

遷移前必須先知道 IAM 目前實際存了哪些 firm 值（**不可假設只有六種名稱**）：

1. 枚舉所有 EmployeeAccess 的 firm distinct 值（可經 KDB 直查 `IAM_GetPermissions-*` 讀模型串流，或加一支臨時查詢）
2. 產出「現有值 → 統編」對照表，**無法對應的值必須逐一人工確認**，不得猜測
3. 已知變體（實測 55 環境）：`台北市所`、`台北所` 同時存在，皆指台北所（`88183980`）

### Step 2 — 遷移（事件溯源正規做法）

對每個 firm 非統編的 EmployeeAccess，發 `transferDepartment` 指令把 firm 改為統編。

- **不用重跑員工匯入**：會覆蓋管理員手動調整過的權限與部門
- `EmployeeAccess+TransferDepartment.swift:9` 的 guard 是「三個欄位皆未變則 no-op」，只改 firm 會正常 emit
- 腳本需冪等（已是統編者跳過），並輸出「處理 N 筆、跳過 M 筆、無法對應 K 筆」摘要
- **先在本機/55 跑過並驗證，才可在正式環境執行**

### Step 3 — scope-check 端點

1. openapi 定義（見 §2）
2. `CheckScopeApplicationService`：對每個 userId 取其 `PermissionsReadModel`，比對 `department`/`firm`（**重用 `GetPermissionHoldersApplicationService.swift:41-60` 的既有比對邏輯**，不要另寫一套）
3. 查不到讀模型的 userId → 排除，不拋錯
4. ApiHandler 接線

### Step 4 — 回歸驗證（跨 repo）

遷移＋端點完成後，實地驗證原始事故情境已解除：分配部門到「審1」→ 該部門具 `AssignStaffMember` 權限者確實成為 assignedUser。

---

## 失敗路徑

| 觸發條件 | 行為 |
|---|---|
| scope-check 的某 userId 在 IAM 無資料 | 靜默排除出 `inScope`（不報錯）—— 呼叫端若需區分「不在範圍」與「查無此人」，需另行查詢 |
| 讀模型不可用 | 503，呼叫端自行決定重試或中止；**呼叫端不得把 503 當成「不在範圍」**（會造成誤刪，見 edit-department spec 的名冊查詢失敗處理） |
| 遷移腳本遇到無法對應的 firm 值 | **中止該筆、不猜測**，列入摘要供人工處理 |
| 遷移中途失敗 | 已處理的筆數已落事件（不可逆但無害：只是 firm 改成統編）；腳本冪等，可直接重跑 |

---

## 不改動的部分

- `EmployeeAccess` 的 `department` 欄位格式（實測 `審1` 等值兩邊一致，**不需要改**）
- `getPermissions` / `getPermissionHolders` 的既有簽名與行為
- IAM 是否應持有組織欄位（另案討論）
- StaffContext 的任何程式碼

### Non-goals（行為層）

- 本 task **不包含** StaffContext → IAM 的組織資料自動同步機制
- 本 task **不包含**移除 `getPermissionHolders` 的 `firm`/`department` 參數
- 本 task **不包含** `WhenHandoverDepartmentAssignedForAnnotating` 的重複過濾清理（該 listener 同時吃 staff 名冊與 IAM 過濾，另案討論）
- 本 task **不修**「IAM 反查回空時 OC 靜默 return」的問題（屬 OC，另案）
- 本 task **不新增** firm 值域驗證

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
# 1. 型別/編譯 gate
swift build

# 2. 測試
swift test --filter CheckScope --no-parallel
swift test --filter PermissionHolders --no-parallel   # 既有行為不得回歸

# 3. 端點存在
grep -q 'operationId: checkScope' Sources/EmployeeAccessAggregate/openapi.yaml && echo OK

# 4. 比對邏輯有重用、沒有第二套實作
grep -c 'readModel.department !=' Sources/EmployeeAccessAggregate/Adapter/*/*.swift   # 應為 1
```

scope-check 單元測試須涵蓋：

- [ ] `userIds` 中部分在範圍、部分不在 → 只回在範圍者
- [ ] `firm` 與 `department` 皆 nil → 回全部（存在於 IAM 者）
- [ ] 只給 `firm` / 只給 `department` → 各自正確限縮
- [ ] `userIds` 含 IAM 查無此人的 id → 靜默排除，不拋錯
- [ ] `userIds` 為空 → 回空陣列、200

### Human 補做（需要人類介入）

- [ ] 遷移腳本在 55 執行後，`GET /employee-access/permission-holders?permission=…AssignStaffMember&firm=88183980&department=審1` **回傳 6 位同仁**（現況回空；名單見 2026-09-03 實測：曾婕瑜、林美汝、黃煒雯、陳嘉貞、陳嘉欣、曾家萍）
- [ ] 同一查詢改用名稱（`firm=台北市所`）→ **回空**（確認已完成切換，不再有名稱資料殘留）
- [ ] 端到端：在 55 對案件分配部門「台北所／審1」→ 上述 6 位成為 assignedUser，能在看板看到該案件
- [ ] mendesky-platform-console 的員工列表：所別欄位仍正確顯示中文名稱（前端對照表轉換），不得顯示裸統編

---

## 已知限制

- **`EmployeeStatus` 是否納入 scope-check 判斷未定**：離職員工若仍有 EmployeeAccess 記錄，目前規格會把他算進 `inScope`。實作時需確認 `PermissionsReadModel` 是否帶 status；若有，建議排除非在職者，並在此更新。
- **`department` 格式未驗證一致性**：本 task 假設兩邊的部門字串（`審1` 等）一致 —— 實測 55 環境 `department=審1` 可正常命中，但未全面盤點所有部門值是否都對得上。若遷移後仍有部門查無人，需另行盤點。
- **遷移不可逆**：firm 改為統編後，若要回退需再跑一次反向遷移（事件會留兩筆變更軌跡）。風險低（欄位語意變更，不影響權限本身）。
- **正式環境資料量未知**：遷移腳本的執行時間與 KDB 負載未評估，建議先在 55 觀察。
- **依賴**：無前置 task。本 task 是 `OpportunityContext` 的 `2026-09-03-edit-department.md` 的前置。
