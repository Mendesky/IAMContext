# I2：role→permission mapping 記載 + grouping 有效權限查詢 API

> ❌ **SUPERSEDED（2026-06-11，user 與夥伴討論定案）**：mapping 與有效權限的回答**回到 OC**——前端從 OC 的 read model 取得「user 對該 grouping 的權限」，IAM 不提供本查詢 API、不記載 mapping。本檔的計算公式（全域 ∩ 角色展開、200-空清單語意、fail-loud mapping 驗證）對 OC 端實作仍有參考價值，保留作決策紀錄。

> 本檔為**手寫 spec**（非 Genesis 機器產物；Genesis 的 per-UC spec 是同目錄的 `<UC>.md`）。

## 來源

討論：`docs/discussions/2026-06-11-grouping-collaboration-in-iam.md`（前置：`docs/tasks/2026-06-11-grouping-collaboration-ingest.md`＝I1）

## 目標

提供前端單一查詢：「**user 在某 grouping 上實際可用的權限**」。計算 = user 的全域權限（既有 GetPermissions read model）∩ 角色展開（I1 的協作者角色 × OC 定義的 role→permission mapping）。mapping 由 **OC 定義、IAM 記載**（deploy 節奏的檔案交付，不做動態管理 API）。

---

## 介面合約（Interface Contract）

### 1. role→permission mapping 檔（OC 交付、IAM 收錄為 resource）

`Sources/GroupingCollaborationAggregate/OpportunityContext.role-mapping.json`（target resource，`Bundle.module` 載入；**JSON 而非 YAML**＝零新依賴，且本檔是 OC 機器產出、無註解需求）：

```json
{
  "context": "OpportunityContext",
  "mapping": [
    { "permission": "OpportunityContext.AuditQuoting.EditAccountingType", "minRole": "editor" },
    { "permission": "OpportunityContext.Query.GetContacts",               "minRole": "viewer" },
    { "permission": "OpportunityContext.QuotingCaseGrouping.AddCollaborators", "minRole": "owner" }
  ]
}
```

- 語意：每條 = 一個 **grouping-scoped** 權限的最低角色（owner ⊇ editor ⊇ viewer 階序）。**非 grouping-scoped 權限（如 createQuotingCaseGrouping、getQuotingCaseGroupingSummaries、uploadEmbeddedImage）不在此檔**——它們不屬於「對某一件案件」的問題，前端用全域權限清單即可。
- 內容由 OC 的「定義 role→permission mapping」task 機械導出（來源＝OC E1 規則分類：grouping-scoped 讀 → viewer、寫 → editor、共編管理＋6 條 lifecycle → owner；含未來 changeCollaboratorRole → owner）。IAM 不審核語意、只驗格式。
- 載入：process 啟動後首次查詢時讀一次並快取（static）；`minRole` 出現未知值 → **fail loud**（拋錯，不靜默略過）。

### 2. 查詢 API（HTTP REST，掛在新 module 自己的 openapi）

```
GET /grouping-collaborations/{groupingId}/permissions/{userId}
```

- 路徑前綴 `grouping-collaborations` 為新命名空間——**不掛 `/employee-access`**，避免與既有路由的 param 位置衝突（A6/G5 教訓），且 `EmployeeAccessAggregate` 維持零改動。
- Response `200`：

```json
{ "role": "editor", "permissions": ["OpportunityContext.AuditQuoting.EditAccountingType", "..."] }
```

- **非協作者／grouping 不存在**：`200` + `permissions: []`、**無 `role` 欄位**（前端友善；非錯誤情境——user 已決策）。
- user 無 IAM 權限檔（GetPermissions read model 不存在）：同樣 `200` + 空清單（有效權限本來就是空）。
- `503`：KDB 等基礎設施失敗。

### 3. 計算（`GetGroupingPermissionsApplicationService`，新 module 的 Adapter）

```swift
// 1. 角色（強一致：讀 aggregate，I1 決策）
let role = try await GroupingCollaborationRepository(coordinator: ...).find(byId: groupingId)?
    .collaborators.first(where: { $0.userId == userId })?.role
guard let role else { return .init(permissions: []) }   // 非協作者短路，不查 global

// 2. 全域權限（精確簽名：execute(input:)，Input 是 struct——勿寫成 execute(userId)）
let global: [String]
do {
    global = try await GetPermissionsApplicationService(kdbClient: kdbClient)
        .execute(input: .init(userId: userId))
} catch let error as ContextError<EmployeeAccessQueryError> where error.error == .notFound {
    global = []    // 無權限檔 = 空全域權限，非錯誤
}

// 3. 交集
let effective = global.filter { p in
    guard let minRole = mapping[p] else { return false }   // mapping 未列 = 非 grouping-scoped，排除
    return rank(role) >= rank(minRole)
}
```

module 依賴方向：`GroupingCollaborationAggregate` → `EmployeeAccessAggregate`（單向，為了重用 `GetPermissionsApplicationService`；反向不存在）。

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---|---|
| `Sources/GroupingCollaborationAggregate/openapi.yaml` + `openapi-generator-config.yaml` | **新檔**：§2 的單一 GET 路徑（formats 照 `EmployeeAccessAggregate` 的 openapi 慣例）|
| `Sources/GroupingCollaborationAggregate/OpportunityContext.role-mapping.json` | **新檔**：OC 交付的 mapping（resource）|
| `Sources/GroupingCollaborationAggregate/Adapter/GetGroupingPermissions/GetGroupingPermissionsApplicationService.swift` | **新檔**：§3 計算 |
| `Sources/GroupingCollaborationAggregate/Adapter/ApiHandler.swift` | **新檔**：openapi handler（鏡像 EmployeeAccess 的 ApiHandler 形狀：200／503）|
| `Sources/GroupingCollaborationAggregate/RoleMapping.swift` | **新檔**：mapping Codable model + `Bundle.module` 載入 + rank helper + fail-loud 驗證 |
| `Sources/IAMContextServer/IAMContextServer.swift` | 註冊第二個 ApiHandler（`registerHandlers(on: router, serverURL: "/")`，比照 OC 多 handler 同 router 的做法）|
| `Package.swift` | `GroupingCollaborationAggregate` target 加：dep `EmployeeAccessAggregate`、**只加 `.product(name: "OpenAPIRuntime", ...)`**（⚠️ 家規分工：aggregate target = OpenAPIRuntime + `OpenAPIGenerator` plugin；`OpenAPIHummingbird` 屬 server target、IAMContextServer 已有，勿加進 aggregate）、resources：`.process("openapi.yaml")`、`.process("openapi-generator-config.yaml")`、`.copy("OpportunityContext.role-mapping.json")` |
| `Tests/IAMContextTests/`（查詢計算測試）| **新測試**：交集邏輯（含 role=nil、global 空、mapping 缺項）`[inferred]` |

**受影響但不改**：`EmployeeAccessAggregate` 全部（含其 openapi——新路徑活在新 module 自己的 openapi）；`GetPermissionsApplicationService`（被重用，不改）。

---

## 實作步驟

### Step 1 — mapping 載入
1. `RoleMapping.swift`：Codable struct（§1 形狀）、`rank(owner)=3/editor=2/viewer=1`、static 快取載入、未知 `minRole` 拋錯。
2. 放入 OC 交付的 json（OC task 未交付前可先放依 E1 分類導出的初版，PR 註明來源與待 OC 確認）。

### Step 2 — openapi + handler + AS
1. 新 module 的 `openapi.yaml`：單一 GET（§2；response schema `role` optional enum + `permissions` array）。
2. AS 照 §3；`role == nil` 短路回空（**不查 global**，省一次讀）。實作註記：`GetPermissionsApplicationService` 是 `package` access、跨 target 需 `EmployeeAccessAggregate` 為依賴且該型別可見（同 package 的不同 module 間 `package` access 可見——同一 SwiftPM package 內成立）。
3. `ApiHandler`：200／catch 全部 → 503（本端點無 404/422 語意——§2 決策）。
4. `IAMContextServer` 註冊 handler。

### Step 3 — 測試
1. **`GetGroupingPermissionsUnitTests`**（純計算，零外部依賴——交集邏輯抽成可注入 mapping/role/global 的 pure function 來測）：交集矩陣（owner 拿到全部 grouping-scoped ∩ global；viewer 只剩 viewer 級；非協作者空；global 缺權限被濾掉；mapping 沒列的權限不出現；未知 minRole fail-loud）。
2. KDB 整合驗證（I1 寫入 owner → 查詢回非空）→ **列在 Human 補做**，不放 Agent filter（既有 integration test pattern 直連 `localhost()`、無自動 skip，混進 mandatory filter 會讓無 KDB 環境的機器驗收必紅）。

---

## 失敗路徑

mapping 檔缺失/格式錯/未知 role → **啟動後首次查詢即拋錯 → 503**（fail loud，寧可壞掉也不靜默回錯誤權限）。`repository.find` / read model 讀取拋錯 → 503。`GetPermissions` 的 `notFound` → **不是錯誤**，視為空全域權限（200 空清單）。

---

## 不改動的部分

`EmployeeAccessAggregate` 全 module；`PermissionsService`（gRPC）；I1 的命令與事件。除「改動檔案」表外均不改動。

### Non-goals（行為層）

- 本 task 不提供 mapping 的動態管理 API（deploy 節奏檔案交付；要改 mapping = OC 重新交付 + IAM 部署）
- 本 task 不做查詢端的身分驗證（IAM HTTP 現況無 auth middleware，與既有 `GET /employee-access/permissions/{userId}` 同等曝露；隨 operatorId 體系迭代處理——user 已決策 deferred）
- 本 task 不改變 OC middleware 的執法 provider（E1 本地版先行）
- 本 task 不回答非 grouping-scoped 權限（前端用既有全域查詢）

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
# preflight：I1 必須已落地（缺任一 = 先做 I1，本 spec 不能單獨套用）
grep -n "GroupingCollaborationAggregate" Package.swift
ls Sources/GroupingCollaborationAggregate/Usecase/Port/Out/GroupingCollaborationRepository.swift

swift build
swift test --filter GetGroupingPermissionsUnitTests   # 純計算，零外部依賴
grep -n "grouping-collaborations" Sources/GroupingCollaborationAggregate/openapi.yaml
grep -n 'copy("OpportunityContext.role-mapping.json")' Package.swift   # resource 以正確宣告註冊於該 target
grep -rn "minRole" Sources/GroupingCollaborationAggregate/RoleMapping.swift
grep -rn "grouping-collaborations" Sources/EmployeeAccessAggregate/openapi.yaml && exit 1 || echo "OK：既有 openapi 未被動到"
```

### Human 補做（需要人類介入）

- [ ] KDB 整合：I1 寫入 owner 後查詢回非空（需 localhost KDB；不在 Agent filter 內，理由見 Step 3）
- [ ] e2e：I1 注入（owner/editor/viewer 各一人）→ `curl GET /grouping-collaborations/{g}/permissions/{userId}` 三種角色各驗一次（owner ⊃ editor ⊃ viewer 的清單包含關係成立）＋ 非協作者回 `200 {"permissions":[]}`
- [ ] 拿掉 mapping json 重啟 → 查詢回 503（fail-loud 生效）
- [ ] 與前端對齊 response 形狀（role 欄位 optional 的處理）

---

## 已知限制

- **資料新鮮度**＝OC listener 的投遞延遲（秒級）；前端呈現可容忍——執法不走本鏈路（E1 本地版）。
- **查詢端無身分驗證**（同既有 IAM HTTP 端點）：知道他人 userId 者可查其在某 grouping 的權限清單。隨 operatorId/auth 迭代處理。
- mapping 是 deploy-time 快照：OC 新增權限後需重新交付 + IAM 部署，否則新權限不會出現在查詢結果（fail-safe 方向：少給不多給）。
- 依賴關係：**I1** 必須先完成（repository 與型別來自該 module）；mapping 內容依賴 OC 的「定義 role→permission mapping」task（可先用導出初版並標注待確認）。
