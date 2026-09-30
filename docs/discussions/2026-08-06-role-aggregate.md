---
topic: Role aggregate — 角色管理（UI 建立角色與設定權限）
date: 2026-08-06
participants: [user, Claude]
status: 決策已鎖定（含 2026-08-07 使用者對 6 個開放問題的裁決 D11–D16）
---

# Role aggregate 討論摘要

> 本檔為 session 內討論的落檔摘要（無獨立多方討論輪次），作為 `docs/tasks/role-aggregate.md` 的來源。

## 議題定義

### 目標

IAMContext 目前沒有「角色」的定義主體：role 只是掛在 `EmployeeAccess` 上的 `Set<String>` 字串集合，
只有 assign-roles / revoke-roles 兩個操作，無法建立、查詢、編輯、刪除角色本身。
使用者需求：**用 UI 介面建立角色、為角色設定權限** → 角色是執行期業務資料 → 建立 Role aggregate。

### 範圍

**討論內（v1）**：
- Role aggregate（ES/CQRS，同 EmployeeAccessAggregate 模式）
- 事件（2026-08-07 定案）：RoleCreated / RoleRenamed / RoleDescriptionUpdated / RolePermissionsAdded / RolePermissionsRemoved / RoleDeleted
- 查詢：getRoles（roleId + name + description 清單）、getRolePermissions（roleId → 權限清單）、getRoleHolders（roleId → 持有者 userId 清單）

**討論外（明確排除，屬後續 task）**：
- 員工有效權限合成（`getPermissions(userId)` = 直接授權 ∪ 角色展開）——跨 context contract 影響面，需照 workspace 鐵則「IAM 先落地、消費端才動」另開 task
- assign-roles 驗證升級（驗角色存在）與歷史 roles 字串資料遷移
- 前端 UI 本身
- gRPC PermissionsService 變更

### 約束

- DDDKit 0.x（Package.resolved 鎖定，不得升 1.x）
- Genesis scaffold 慣例：一個 aggregate 一個 target，event.yaml / openapi.yaml / projection-model.yaml 驅動 codegen
- KurrentDB projection 部署是手動步驟（`scripts/projection.sh`）

## 決策紀錄

| # | 決策 | 狀態 |
|---|---|---|
| D1 | Role 建為獨立 aggregate（非 YAML catalog）——理由：UI 執行期管理需求成立後，catalog 走部署流程的路死掉；ES 附帶 IAM 合規需要的 audit trail | agreed |
| D2 | 新 SPM target `RoleAggregate`，鏡像 EmployeeAccessAggregate 結構（Entity/Commands、Usecase Port-In/Out/Service/Projector、Adapter） | agreed |
| D3 | ~~事件四個：RoleCreated / PermissionAdded / PermissionRemoved / RoleDeleted~~ **由 D11–D14 取代**：六個事件、批次、帶 Role 前綴 | superseded |
| D4 | 「以 roleId 查權限」的 operationId 用 `getRolePermissions`——`getPermissions` 已被 employee 查詢佔用（命名衝突盤點證實） | agreed |
| D5 | `getRolePermissions` 走 aggregate rehydrate（`RoleRepository.find(byId:)`）——強一致、免 projection；不存在/已刪除 → 404。~~roleId 由 client 供給~~ **id 生成方式由 D15 取代** | agreed（部分由 D15 修訂） |
| D6 | `getRoles` 走 KDB projection（`$ce-IAMRole` → linkTo 固定 stream `IAM_GetRoles-all`）+ presenter 折疊——同 GetPermissionHolders 模式；最終一致 | agreed |
| D7 | AddPermissions 驗證 permission ∈ PermissionCatalog（IAMPermissionCatalog target；Package.swift 註解明示該 catalog 即為 role 設計預留的權限 universe）；驗證放 usecase 層，aggregate 不依賴 catalog target | agreed |
| D8 | 角色名稱唯一性：v1 做 best-effort（create 與 rename 時查 GetRoles read model），race window 記入已知限制；嚴格唯一（reservation pattern）defer | agreed |
| D9 | 刪除仍被員工持有的角色：允許刪除，懸空引用 fail-safe deny（在有效權限合成 task 處理），與既有 403 哲學一致 | agreed |
| D10 | 變更端點沿用 AdminTokenMiddleware Bearer token 守門（server-level 既有行為）；GET 放行 | agreed |
| D11 | **權限操作改批次**（使用者 2026-08-07 裁決）：`RolePermissionsAdded` / `RolePermissionsRemoved` 帶 `permissions: Set<String>`；事件記錄**淨效果**（add = 請求−當前、remove = 請求∩當前）；淨效果空 → `permissionsUnchanged`；catalog 驗證整批原子（任一不合法整批拒絕） | agreed |
| D12 | **需要 rename**（使用者裁決）：`RoleRenamed {newName}` + `POST /roles/{roleId}/rename`；rename 也做名稱唯一性 best-effort（排除自身）；no-op → `roleNameUnchanged` | agreed |
| D13 | **需要 description**（使用者裁決）：`RoleCreated` 帶 `description: String?`；可經 `RoleDescriptionUpdated` + `POST /roles/{roleId}/update-description` 編輯；`getRoles` 回傳含 description | agreed |
| D14 | **事件帶 Role 前綴**（使用者裁決）：原 `RolePermissionAdded` 因 D11 批次化正規化為複數 `RolePermissionsAdded` / `RolePermissionsRemoved` | agreed |
| D15 | **roleId 由 aggregate 自行生成**（使用者裁決）：create init 內 `UUID().uuidString`；create 端點改 `POST /roles`（無 path id），200 回傳生成的 roleId；create 重複檢查（roleAlreadyExists）移除——UUID 碰撞可忽略 | agreed |
| D16 | **GetRoleHolders（角色持有者反查）進 v1**（使用者裁決）：落在 **EmployeeAccessAggregate**（折疊 `RolesAssigned`/`RolesRevoked`，該 module 內部生成型別；完全鏡像 GetPermissionHolders），端點 `GET /employee-access/role-holders?role=<roleId>`，命名對稱 permission-holders；key = `EmployeeAccess.roles` 字串原值，慣例自本 task 起 assign-roles 傳 roleId；v1 不做 department/firm 過濾 | agreed |

## 開放問題

（2026-08-07 全數由使用者裁決，結案如下；無未決事項）

1. ~~批次設定權限？~~ → **改批次**（D11）
2. ~~角色改名？~~ → **需要 rename**（D12）
3. ~~description 欄位？~~ → **要**（D13）
4. ~~事件名前綴？~~ → **RolePermissionAdded 方向，批次化後為 RolePermissionsAdded/Removed**（D14）
5. ~~roleId 生成者？~~ → **aggregate 自己生成**（D15）
6. ~~GetRoleMembers？~~ → **現在排進去**，實作為 GetRoleHolders（D16）
