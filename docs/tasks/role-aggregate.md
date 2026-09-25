# Role Aggregate — 角色管理（UI 建立角色與設定權限）

## 來源

討論：`docs/discussions/2026-08-06-role-aggregate.md`（開放問題已於 2026-08-07 由使用者裁決，見該檔 D11–D16）

## 目標

IAMContext 目前沒有「角色」的定義主體——role 只是 `EmployeeAccess` 上的 `Set<String>` 字串集合，僅有 assign/revoke 兩個操作，無法建立、查詢、編輯、刪除角色本身。本 task 建立 **Role aggregate** 作為角色定義的 SSOT，讓管理者能經 UI 在執行期：建立角色（含描述）、改名、批次增減權限、刪除角色，並查詢角色清單、單一角色的權限、以及某角色的持有者（role holders 反查）。這同時為後續「員工有效權限 = 直接授權 ∪ 角色展開」鋪路（該合成**不在**本 task 範圍，見 Non-goals）。

---

## 介面合約（Interface Contract）

### 1. 事件（`Sources/RoleAggregate/event.yaml`，DomainEventGeneratorPlugin 生成 struct）

| Event | kind | aggregateRootId alias | properties |
|---|---|---|---|
| `RoleCreated` | `createdEvent` | `roleId` | `name: "String"`、`description: "String?"` |
| `RoleRenamed` | `domainEvent` | `roleId` | `newName: "String"` |
| `RoleDescriptionUpdated` | `domainEvent` | `roleId` | `newDescription: "String?"` |
| `RolePermissionsAdded` | `domainEvent` | `roleId` | `permissions: "Set<String>"` |
| `RolePermissionsRemoved` | `domainEvent` | `roleId` | `permissions: "Set<String>"` |
| `RoleDeleted` | `deletedEvent` | `roleId`（見實作回填 #1） | （無） |

- 事件帶 `Role` 前綴（使用者 2026-08-07 裁決，D14）；因權限操作改批次（D11），使用者原名 `RolePermissionAdded` 正規化為複數 `RolePermissionsAdded` / `RolePermissionsRemoved`。
- **批次事件記錄「淨效果」**：`RolePermissionsAdded.permissions` 只含實際新增的權限（請求集合 − 當前集合）；`RolePermissionsRemoved.permissions` 只含實際移除的（請求集合 ∩ 當前集合）——replay 精確、不含 no-op 項。
- 生成的 struct 自動含 `id: UUID`、`occurred: Date`、`roleId: String`（DDDKit `DomainEvent` protocol 要求）。

### 2. Aggregate（`Sources/RoleAggregate/Entity/Role.swift`）

```swift
package class Role: RoleAggregateProtocol {   // protocol 由 plugin 從 event.yaml 生成 [inferred]
    package let id: String                     // roleId；aggregate 自行生成（見下）
    package var metadata: AggregateRootMetadata = .init()
    package var name: String?
    package var description: String?
    package var permissions: Set<String>?
    // category 沿用 EmployeeAccess 的寫法："IAM\(Self.self)" → "IAMRole"
    // → per-aggregate stream "IAMRole-<roleId>"、category stream "$ce-IAMRole"
}
```

- **roleId 由 aggregate 自行生成**（D15）：create 用的 convenience init `Role(name:description:)` 內部 `id = UUID().uuidString`，client 不供給 id；因 UUID 碰撞機率可忽略，**不做** create 重複檢查（對照 `CreateUserAccessProfileUsecase` 的 duplicate guard——那是 client 供給 id 才需要的）。
- **不變量**（`ensureInvariant`）：`name` 非 nil 且非空字串（違反 → `ContextError<RoleError>.roleNameRequired`）。
- **狀態異動只在 `when(event:)`**；命令方法只 validate + `apply(event:)`（repo 鐵則，對照 `EmployeeAccess+TransferDepartment` 的命令方法與 `when(event:)` 分工）。

命令（`Entity/Commands/`，每命令一檔）：

| 命令方法 | 前置守門（guard） | emit | when(event:) 狀態異動 |
|---|---|---|---|
| `Role+Rename` | `newName` ≠ 當前 name，否則拋 `roleNameUnchanged` | `RoleRenamed` | `name = newName` |
| `Role+UpdateDescription` | `newDescription` ≠ 當前值，否則拋 `descriptionUnchanged` | `RoleDescriptionUpdated` | `description = newDescription` |
| `Role+AddPermissions` | 淨新增集合（請求 − 當前）非空，否則拋 `permissionsUnchanged` | `RolePermissionsAdded`（帶淨集合） | `permissions.formUnion` |
| `Role+RemovePermissions` | 淨移除集合（請求 ∩ 當前）非空，否則拋 `permissionsUnchanged` | `RolePermissionsRemoved`（帶淨集合） | `permissions.subtract` |
| `Role+Delete` | — | `RoleDeleted`（由 `repository.delete` 觸發，其內部呼叫 `markDelete()`；本檔只實作 `when(event:)`） | — |

建立走 `Role(name:description:)` convenience init：emit `RoleCreated`，`when` 設定 `name`、`description`、`permissions = []`。**初始權限不在 create 帶入**——UI 建立角色後以一次批次 `add-permissions` 設定（create 表單與權限勾選分兩個請求，語意正交、事件精簡）。

### 3. HTTP API

#### 3a. RoleAggregate 側（`Sources/RoleAggregate/openapi.yaml`，OpenAPIGenerator 生成 `APIProtocol`）

| Method / Path | operationId | 輸入 | 200 回應 |
|---|---|---|---|
| `POST /roles` | `createRole` | body `{name: String, description: String?}`；header `operatorId` | `{roleId}`（server 生成之 UUID 字串） |
| `POST /roles/{roleId}/rename` | `renameRole` | body `{newName: String}`；header `operatorId` | `{roleId}` |
| `POST /roles/{roleId}/update-description` | `updateRoleDescription` | body `{newDescription: String?}`；header `operatorId` | `{roleId}` |
| `POST /roles/{roleId}/add-permissions` | `addPermissions` | body `{permissions: [String]}`；header `operatorId` | `{roleId}` |
| `POST /roles/{roleId}/remove-permissions` | `removePermissions` | body `{permissions: [String]}`；header `operatorId` | `{roleId}` |
| `DELETE /roles/{roleId}` | `deleteRole` | header `operatorId` | `{roleId}` |
| `GET /roles` | `getRoles` | — | `[{roleId: String, name: String, description: String?, permissions: [String]}]` |
| `GET /roles/{roleId}/permissions` | `getRolePermissions` | — | `[String]` |

- **命名衝突迴避**：operationId `getPermissions` 已被 employee 查詢（`GET /employee-access/permissions/{userId}`）佔用 → 本 aggregate 用 `getRolePermissions`。
- **錯誤回應**（全 endpoint 一致，對照 EmployeeAccess openapi.yaml 的 responses 慣例）：`404` NotFoundError（aggregate 不存在/已刪除）、`422` UnprocessableEntityError（`RoleApiError` enum）、`503` ServiceUnavailableError。
- `POST /roles`（無 path id）與 `DELETE` 動詞皆無 repo 先例 [inferred]；若 OpenAPIGenerator/Hummingbird 有陷阱，fallback 分別為「path 帶 server 端忽略的佔位」不採用——改為維持 `POST /roles` 但確認 generator 輸出；`DELETE` 的 fallback 為 `POST /roles/{roleId}/delete`。
- **守門所有權**：變更端點（POST/DELETE）由 **server-level 的 `AdminTokenMiddleware`** 自動守門（`Authorization: Bearer <IAM_ADMIN_API_TOKEN>`，GET/OPTIONS 放行）——middleware 掛在 router 層，本 task **不需**、也**不得**另行設定 per-route 守門。

#### 3b. EmployeeAccessAggregate 側（role holders 反查，`Sources/EmployeeAccessAggregate/openapi.yaml` 新增）

| Method / Path | operationId | 輸入 | 200 回應 |
|---|---|---|---|
| `GET /employee-access/role-holders?role=<roleId>` | `getRoleHolders` | query `role`（必填） | `[String]`（userId 清單） |

- **放在 EmployeeAccessAggregate 的理由**（D16）：此查詢折疊的是 `RolesAssigned` / `RolesRevoked`——EmployeeAccess 的事件，生成型別是該 module 內部符號；且形狀與既有 `GET /employee-access/permission-holders` 完全鏡像（permission→holders vs role→holders），沿用同一套 projector/projection 模式，命名取 `role-holders` 對稱 `permission-holders`。
- 無人持有或 role 不存在 → `[]`（鏡像 permission-holders 的 unknown-permission 行為，不回 404）。
- **key 語意**：以 `EmployeeAccess.roles` 內儲存的**字串原值**分流。自本 task 起的慣例：`assign-roles` 應傳 **roleId**；歷史資料若存的是名稱字串，用 roleId 反查不到（記入已知限制 #3）。

### 4. 查詢一致性語意（外部可觀察行為）

| 查詢 | 實作路徑 | 一致性 | 空/缺結果行為 |
|---|---|---|---|
| `getRolePermissions` | `RoleRepository.find(byId:)` rehydrate aggregate 自身 stream | **強一致**（寫後立即可讀） | 角色不存在或已刪除 → `404`；存在但無權限 → `[]` |
| `getRoles` | KDB projection `IAM_GetRolesProjection.js`（`$ce-IAMRole` → `linkTo("IAM_GetRoles-all")`）+ presenter 折疊 | **最終一致**（projection lag，實測數百 ms 級） | 無任何角色 → `[]` |
| `getRoleHolders` | KDB projection `IAM_RoleHoldersProjection.js`（`$ce-IAMEmployeeAccess` → per-role `linkTo`）+ presenter 折疊 | **最終一致** | 無人持有 → `[]` |

- `find(byId:)` 對已刪除 aggregate 回 nil（DDDKit `hiddingDeleted` 預設）→ 刪除後查詢自然 404，fail-safe。
- `getRoles` / `getRoleHolders` 回傳**順序不保證**。

### 5. 錯誤型別（`Sources/RoleAggregate/RoleError.swift`）

```swift
package enum RoleError: Error, Equatable {
    case roleNameRequired       // name 空字串（invariant / create 輸入）
    case roleNameDuplicated     // create/rename：名稱已被其他角色使用（best-effort，見 §7）
    case roleNameUnchanged      // rename no-op
    case descriptionUnchanged   // update-description no-op
    case permissionsUnchanged   // 批次 add/remove 淨效果為空
    case invalidPermission      // 批次中任一權限不在 PermissionCatalog universe（整批拒絕）
}
```

拋出格式沿用 repo 慣例：`throw ContextError<RoleError>.<factory>(...)`，並比照 `EmployeeAccessError.swift` 提供 `extension ContextError where ErrorType == RoleError` 的 static factory。HTTP 映射：`RoleError` → `422`（`ApiComponents+RoleApiError` 1:1 映射到 openapi schema enum）；`DDDError` 的 `aggregateNotFound` → `404`；其餘 → `503`。

注意：`EmployeeAccessError` 已有 `permissionAlreadyExists` / `roleAlreadyExists` 等語意相近的 case（那是「該員工已持有該字串」的語意）。兩者屬不同 enum，factory 分別掛在 `ContextError<EmployeeAccessError>` 與 `ContextError<RoleError>` 兩個不同泛型特化的 extension 上，Swift 型別系統可完全區分，**無衝突、不需改名**。

no-op 類錯誤（`roleNameUnchanged` / `descriptionUnchanged` / `permissionsUnchanged`）沿用 repo 既有精神（對照 `transferDepartment` 的 `departmentUnchanged` guard）：重送或未變更即拒絕。UI 端應把這三種 422 視為良性（畫面已是目標狀態）。

### 6. 權限合法性驗證（AddPermissions 專屬）

- 批次中**每一個** `permission` 必須 ∈ `IAMPermissionCatalog` target 生成的權限 universe（`PermissionCatalogPlugin` 於 build 時聚合各 context 的 `*.permissions.yaml` → `PermissionCatalog.swift`；Package.swift 中該 target 的註解明示其用途即「供未來 role 設計 / 授權 UI 的權限選單」）。任一不合法 → 拋 `invalidPermission`，**整批原子拒絕**（不部分套用）。
- **驗證位置：`AddPermissionsUsecase` 的 `execute` 默認實作**（Port/In 層），不放 Entity——aggregate 保持不依賴 catalog target。
- [inferred] 生成符號的確切名稱與 access level 需在實作第一步確認（build 後檢查 `PermissionCatalog.swift` build product）；若 visibility 不足（非 `package`/`public`），fallback：於 RoleAggregate target 內以 `PermissionGenPlugin` 機制或手動引入 catalog 清單，實作時擇一並記錄。

### 7. 角色名稱唯一性（best-effort）

唯一性檢查在 **Adapter 層的 `CreateRoleApplicationService` / `RenameRoleApplicationService`** 做——usecase 只持有 `RoleRepository`，而查 `GetRoles` read model 需要 `KurrentDBClient`（`KurrentStorageCoordinator` 不對外暴露 client）；application service 同時持有兩者，寫入前先查 read model。**佈線方式**：兩個依賴都由 ApiHandler 供給——對照 EmployeeAccess 的 `ApiHandler(kdbClient:)`，它以 kdbClient 建構並持有 repository，再把 repository 傳給 mutating application services、把 kdbClient 傳給 query application services；Create/Rename 的 application service 只是把同一來源的兩個依賴一起收（`init(repository:kdbClient:)`），無新機制（外部審查曾以「無雙依賴先例」質疑，仲裁採此佈線證據）。同名（大小寫敏感、完全比對；rename 時排除自身 roleId）→ 拋 `roleNameDuplicated`。read model 最終一致 ⇒ 存在 race window（兩個同名寫入幾乎同時到達可能都成功），記入已知限制；嚴格唯一性（reservation pattern）明確 defer。

---

## 改動檔案

### 新增（`Sources/RoleAggregate/` 鏡像 EmployeeAccessAggregate 結構）

| 檔案 | 說明 |
|---|---|
| `Sources/RoleAggregate/event.yaml` | 6 個事件定義（介面合約 §1） |
| `Sources/RoleAggregate/event-generator-config.yaml` | 複製 EmployeeAccessAggregate 同名檔並改 aggregate 名 [inferred] |
| `Sources/RoleAggregate/openapi.yaml` | 8 個 endpoint（介面合約 §3a） |
| `Sources/RoleAggregate/openapi-generator-config.yaml` | 複製既有檔的 generator 設定 |
| `Sources/RoleAggregate/projection-model.yaml` | `GetRoles: {model: readModel, events: [RoleCreated, RoleRenamed, RoleDescriptionUpdated, RolePermissionsAdded, RolePermissionsRemoved, RoleDeleted]}` |
| `Sources/RoleAggregate/RoleError.swift` | domain error enum + ContextError factory（介面合約 §5） |
| `Sources/RoleAggregate/Entity/Role.swift` | aggregate root（介面合約 §2） |
| `Sources/RoleAggregate/Entity/Commands/Role+Rename.swift` | 命令 + when |
| `Sources/RoleAggregate/Entity/Commands/Role+UpdateDescription.swift` | 命令 + when |
| `Sources/RoleAggregate/Entity/Commands/Role+AddPermissions.swift` | 命令 + when（淨效果批次） |
| `Sources/RoleAggregate/Entity/Commands/Role+RemovePermissions.swift` | 命令 + when（淨效果批次） |
| `Sources/RoleAggregate/Entity/Commands/Role+Delete.swift` | 只含 `when(event: RoleDeleted)`（命令路徑走 `repository.delete`，見 Step 2） |
| `Sources/RoleAggregate/Usecase/Port/Out/RoleRepository.swift` | `EventSourcingRepository` wrapper（對照 `EmployeeAccessRepository`） |
| `Sources/RoleAggregate/Usecase/Port/In/CreateRole/{Input,Output,Usecase}.swift` | create（server 生成 roleId） |
| `Sources/RoleAggregate/Usecase/Port/In/RenameRole/{Input,Output,Usecase}.swift` | rename（no-op guard 在 Entity） |
| `Sources/RoleAggregate/Usecase/Port/In/UpdateRoleDescription/{Input,Output,Usecase}.swift` | |
| `Sources/RoleAggregate/Usecase/Port/In/AddPermissions/{Input,Output,Usecase}.swift` | 含 catalog 整批驗證（§6） |
| `Sources/RoleAggregate/Usecase/Port/In/RemovePermissions/{Input,Output,Usecase}.swift` | |
| `Sources/RoleAggregate/Usecase/Port/In/DeleteRole/{Input,Output,Usecase}.swift` | |
| `Sources/RoleAggregate/Usecase/Service/{CreateRole,RenameRole,UpdateRoleDescription,AddPermissions,RemovePermissions,DeleteRole}Service.swift` | usecase 具體型別（各一檔） |
| `Sources/RoleAggregate/Usecase/Projector/GetRoles/RolesReadModel.swift` | `roles: [{roleId, name, description?, permissions: [String]}]`；id 固定 `"all"` |
| `Sources/RoleAggregate/Usecase/Projector/GetRoles/GetRolesPresenter.swift` | 折疊 Created/Renamed/DescriptionUpdated/PermissionsAdded/PermissionsRemoved/Deleted |
| `Sources/RoleAggregate/Adapter/ApiHandler.swift` | APIProtocol 實作（8 個 handler method） |
| `Sources/RoleAggregate/Adapter/ApiComponents/ApiComponents+RoleApiError.swift` | domain error → openapi enum 映射 |
| `Sources/RoleAggregate/Adapter/{CreateRole,RenameRole,UpdateRoleDescription,AddPermissions,RemovePermissions,DeleteRole,GetRoles,GetRolePermissions}/*ApplicationService.swift` | 8 個 application service；CreateRole/RenameRole 另持 kdbClient 做名稱唯一性 best-effort（§7） |
| `projections/IAM_GetRolesProjection.js` | KDB continuous projection（需手動部署） |
| `Tests/IAMContextTests/RoleIntegrationTests.swift` | 整合測試（見驗收標準） |

### 新增（EmployeeAccessAggregate 側，role holders 反查） 

| 檔案 | 說明 |
|---|---|
| `Sources/EmployeeAccessAggregate/Usecase/Projector/GetRoleHolders/RoleHoldersReadModel.swift` | `id = role 字串`；`userIds: [String]`（鏡像 `PermissionHoldersReadModel`） |
| `Sources/EmployeeAccessAggregate/Usecase/Projector/GetRoleHolders/GetRoleHoldersPresenter.swift` | 折疊 `RolesAssigned`（加 userId）/ `RolesRevoked`（移除） |
| `Sources/EmployeeAccessAggregate/Adapter/GetRoleHolders/GetRoleHoldersApplicationService.swift` | 無人持有回 `[]`（鏡像 GetPermissionHolders，見實作回填 #2） |
| `projections/IAM_RoleHoldersProjection.js` | KDB continuous projection（需手動部署；鏡像 `IAM_PermissionHoldersProjection.js`，迭代 `event.body["roles"]`） |

### 修改

| 檔案 | 改動描述 |
|---|---|
| `Package.swift` | 新增 `RoleAggregate` target（依賴/資源/plugins 與 `EmployeeAccessAggregate` target 宣告同形 + `IAMPermissionCatalog` 依賴）；`IAMContextServer` 與 `IAMContextTests` 的 dependencies 各加 `RoleAggregate` |
| `Sources/IAMContextServer/IAMContextServer.swift` | 在既有 `EmployeeAccessAggregate.ApiHandler(...).registerHandlers` 呼叫之後，加一行 `RoleAggregate.ApiHandler(kdbClient:).registerHandlers(on:router, serverURL:"/")` |
| `Sources/EmployeeAccessAggregate/openapi.yaml` | 新增 `GET /employee-access/role-holders` 端點（§3b）；**既有 paths 一律不動** |
| `Sources/EmployeeAccessAggregate/projection-model.yaml` | 新增 `GetRoleHolders: {model: readModel, events: [RolesAssigned, RolesRevoked]}`；既有兩個讀模型定義不動 |
| `Sources/EmployeeAccessAggregate/Adapter/ApiHandler.swift` | 新增 `getRoleHolders` handler method；既有 method 不動 |

### 受影響呼叫端（不需修改，列出供 review）

- `scripts/projection.sh` — 自動掃 `projections/*Projection.js`，會一併部署兩個新檔，無需改動。
- `AdminTokenMiddleware` — router-level，自動涵蓋新的 POST/DELETE 端點；新 GET 端點自動放行，無需改動。

---

## 實作步驟

### Step 0：Package.swift + 骨架

1. `Package.swift` 新增 target（與 `EmployeeAccessAggregate` target 宣告同形）：
   - dependencies：`DDDKit`、`IAMContextShared`（`ApplicationService` protocol 在此）、`OpenAPIRuntime`、**`IAMPermissionCatalog`**（catalog 驗證用）
   - resources：`.process("openapi.yaml")`、`.process("openapi-generator-config.yaml")`
   - plugins：`DomainEventGeneratorPlugin`、`ModelGeneratorPlugin`（注意：plugin 名是 `ModelGeneratorPlugin`，非 ProjectionModelGeneratorPlugin）、`OpenAPIGenerator`
2. `IAMContextServer`、`IAMContextTests` 兩個 target 的 dependencies 加 `RoleAggregate`。
3. 建立 5 個 yaml（event / event-generator-config / openapi / openapi-generator-config / projection-model）。config 檔以 EmployeeAccessAggregate 的同名檔為底，改 aggregate 名。
4. `swift build` 確認 codegen 產出 `RoleAggregateProtocol`、6 個 event struct、`APIProtocol`、`GetRolesProjectorProtocol`，**並確認 `PermissionCatalog` 生成符號的名稱與 visibility**（介面合約 §6 的 [inferred] 項）。此步 build 允許紅（實作檔未齊），目的是看 codegen 輸出形狀。

### Step 1：Entity 層

1. `Role.swift`：宣告照介面合約 §2；三個 init——主 init（全欄位）、convenience create init `Role(name:description:)`（內部生成 `id = UUID().uuidString`，emit `RoleCreated`）、`required convenience init?(first:other:)` replay 入口（三件組對照 `EmployeeAccess.swift` 同名 init）。**主 init 必須先直接初始化狀態欄位（name/description/permissions）再 `apply(event:)`**——DDDKit 的 `apply` 在 `when(happened:)` 之前就會先跑一次 `ensureInvariant()`，欄位若仍為 nil 會在不變量檢查失敗（對照 `EmployeeAccess.init` 既有寫法：先設欄位、後 apply）。
2. `ensureInvariant`：name 非空。
3. 四個命令 extension（Rename / UpdateDescription / AddPermissions / RemovePermissions）：guard → 算淨效果（批次類）→ event → `self.apply(event:)`；狀態異動只在 `when(event:)`。`Role+Delete.swift` **只實作 `when(event: RoleDeleted)`**（命令路徑走 repository.delete，見 Step 2）。

### Step 2：Usecase 層

1. `RoleRepository.swift`：對照 `EmployeeAccessRepository`——`EventSourcingRepository` wrapper，`StorageCoordinator = KurrentStorageCoordinator<Role>`。
2. `CreateRoleUsecase.execute` 默認實作：
   a. `name` 非空驗證（空 → `roleNameRequired`）
   b. `Role(name:description:)`（roleId 於此生成）→ `repository.save(aggregateRoot:userId: input.operatorId)` → Output 回傳生成的 roleId
   （名稱唯一性檢查**不在** usecase——它只持有 repository，拿不到 kdbClient；檢查位置在 Adapter 層，見 §7 與 Step 4。）
3. `RenameRoleUsecase.execute`：find（nil → aggregateNotFound）→ `role.rename(...)` → save（唯一性檢查同樣在 Adapter 層）。
4. `AddPermissionsUsecase.execute`：
   a. 整批 catalog 驗證（§6），任一不合法 → `invalidPermission`
   b. `repository.find(byId:)`，nil → aggregateNotFound
   c. `role.addPermissions(...)`（淨效果空 → `permissionsUnchanged`）→ save
5. `UpdateRoleDescription` / `RemovePermissions` 同形。`DeleteRoleUsecase` 走 `repository.delete(byId:external:)`——外部審查已對照 DDDKit 原始碼確認：此方法**內部會呼叫 `markDelete()` 並 emit DeletedEventType**，不需（也不得）另寫 mark-delete 命令方法，避免重複路徑；`Role+Delete.swift` 只保留 `when(event: RoleDeleted)`（對照 `EmployeeAccess+Delete.swift` 同樣只含 when）。
6. 六個 `*Service.swift`：只是 `package struct XxxService: XxxUsecase { package let repository: RoleRepository }`。

### Step 3：Projector 層

**GetRoles（RoleAggregate 側）**

1. `RolesReadModel`：`id` 固定回 `"all"`；`roles: [RoleSummary]`（roleId + name + description?）。
2. `GetRolesPresenter`：`categoryRule = .fromClass(withPrefix: "IAM_")` → 讀 stream `IAM_GetRoles-all`；when handlers：`RoleCreated` → append、`RoleRenamed` → 以 roleId 找到後改 name、`RoleDescriptionUpdated` → 改 description、`RolePermissionsAdded` → 以 roleId 找到後 union、`RolePermissionsRemoved` → 以 roleId 找到後 subtract、`RoleDeleted` → remove。
3. `projections/IAM_GetRolesProjection.js`：

```js
fromStreams(["$ce-IAMRole"])
.when({
    $init: function(){ return {} },
    RoleCreated: link,
    RoleRenamed: link,
    RoleDescriptionUpdated: link,
    RolePermissionsAdded: link,
    RolePermissionsRemoved: link,
    RoleDeleted: link,
});
function link(state, event) {
    if (!event.isJson) { return; }
    linkTo("IAM_GetRoles-all", event);   // 單一固定 partition：全角色清單
}
```

**GetRoleHolders（EmployeeAccessAggregate 側，鏡像 GetPermissionHolders）**

4. `RoleHoldersReadModel`：`id` = role 字串；`userIds: [String]`（對照 `PermissionHoldersReadModel`）。
5. `GetRoleHoldersPresenter`：讀 stream `IAM_GetRoleHolders-<role>`；`RolesAssigned` → 加 userId、`RolesRevoked` → 移除（對照 `GetPermissionHoldersPresenter` 的 grant/revoke 折疊）。
6. `projections/IAM_RoleHoldersProjection.js`（對照 `IAM_PermissionHoldersProjection.js`，欄位換成 `roles`）：

```js
fromStreams(["$ce-IAMEmployeeAccess"])
.when({
    $init: function(){ return {} },
    RolesAssigned: handleEvent,
    RolesRevoked: handleEvent,
});
function handleEvent(state, event) {
    if (!event.isJson) { return; }
    var roles = event.body["roles"];
    for (var i = 0; i < roles.length; i++) {
        linkTo("IAM_GetRoleHolders-" + roles[i], event);
    }
}
```

### Step 4：Adapter 層

1. RoleAggregate 側 8 個 ApplicationService：mutating 六個接 `repository`；**`CreateRole` 與 `RenameRole` 另接 `kdbClient`**——先建 `GetRolesPresenter` 查 read model 做名稱唯一性 best-effort（§7，同名拋 `roleNameDuplicated`），通過才呼叫對應 Service；`GetRoles` 接 `kdbClient` 建 presenter（對照 `GetPermissionsApplicationService` 直接收 `KurrentDBClient` 的寫法）；`GetRolePermissions` 接 `repository`，`find` nil → 拋 aggregateNotFound、否則回 `Array(role.permissions ?? [])`。
2. EmployeeAccess 側 `GetRoleHoldersApplicationService`：接 `kdbClient`，無人持有回 `[]`（對照 `GetPermissionHoldersApplicationService`，見實作回填 #2）。
3. 兩邊 `ApiHandler`：RoleAggregate 新建（8 個 operation method）；EmployeeAccess 既有檔案加 `getRoleHolders` 一個 method。錯誤處理三段式照 repo 慣例——`DDDError` 且 code 為 `aggregateNotFound` → `.notFound`；`mapToApiError` 命中 → `.unprocessableContent`；其餘 → `.serviceUnavailable`。
4. `ApiComponents+RoleApiError.swift`：`RoleError` 各 case 1:1 映射 openapi schema enum。

### Step 5：Server 掛載

`IAMContextServer.swift` 的 `registerHandlers` 區段加一行（改動檔案表）。gRPC services 陣列**不動**。

### Step 6：整合測試

`RoleIntegrationTests.swift`，組織對照 `GetPermissionHoldersIntegrationTests`（`@Suite(.serialized)`、直連 `KurrentDB localhost`、`withTestBundle` id 隔離；等 projection 用 `Task.sleep`）：

| 測試 | 需要 projection 部署？ |
|---|---|
| `create_returns_generated_uuid_roleId` | 否 |
| `create_add_remove_permissions_batch_roundtrip`（批次加 3 → 移 2 → `getRolePermissions` 剩 1，強一致直讀） | 否 |
| `rename_updates_name_and_noop_rename_throws` | 否 |
| `update_description_roundtrip_and_noop_throws` | 否 |
| `add_batch_with_invalid_permission_rejects_whole_batch` | 否 |
| `add_batch_net_empty_throws_permissionsUnchanged` | 否 |
| `remove_partial_batch_removes_only_present` | 否 |
| `deleted_role_returns_notFound_on_getRolePermissions` | 否 |
| `getRoles_reflects_create_rename_permissions_delete`（含 add/remove-permissions 後清單內該角色 `permissions` 正確；`Task.sleep` 等 projection） | **是** |
| `create_duplicate_name_throws`（best-effort；需 projection） | **是** |
| `assign_then_revoke_roles_reflects_in_role_holders`（用 `seedActiveProfile` + `AssignRolesService`/`RevokeRolesService`） | **是** |
| `role_holders_unknown_role_returns_empty` | 否 |

---

## 失敗路徑

- **createRole 空名稱**：usecase 拋 `roleNameRequired` → `422`。可恢復。
- **create/rename 撞名**：best-effort 檢查拋 `roleNameDuplicated` → `422`。可恢復（race window 見已知限制 #1）。
- **rename/update-description/批次 no-op**：`roleNameUnchanged` / `descriptionUnchanged` / `permissionsUnchanged` → `422`。良性（UI 視為已達目標狀態）。
- **操作不存在的 roleId**：`repository.find` nil → `DDDError`（code `aggregateNotFound`）→ `404`。可恢復。
- **add-permissions 批次含 catalog 外權限**：`invalidPermission` → `422`，**整批原子拒絕**（UI 權限選單本就該來自 catalog，理論上不會發生）。
- **KurrentDB 不可用**：底層丟非 domain error → `503 serviceUnavailable`。不可恢復（infra）。
- **getRoles / getRoleHolders 而 projection 未部署**：對應 stream 不存在 → presenter 無資料 → 回 `[]`（**靜默回空結果**，不是錯誤——與 `GetPermissionHolders` 的 unknown-permission 行為一致；部署 projection 是驗收前置步驟，記入已知限制；見實作回填 #2）。

---

## 不改動的部分

- `Sources/EmployeeAccessAggregate/` 中除「改動檔案」表列出的三個檔案（openapi.yaml、projection-model.yaml、Adapter/ApiHandler.swift 的**新增段落**）與新增的 GetRoleHolders 目錄外，其餘全部不動——特別是 `Entity/`、`Usecase/Port/`、`Usecase/Service/`、既有兩個 Projector、`event.yaml`、`EmployeeAccessError.swift`。
- `Sources/Generated/`（gRPC contract）、`proto/`、gRPC `PermissionsService` 與其 interceptor。
- `Sources/IAMPermissionCatalog/` 的各 context yaml（只**讀**其 build 產物，不改內容）。
- `Sources/IAMContextServer/AdminTokenMiddleware.swift`、`BearerTokenServerInterceptor.swift`。
- `projections/` 既有 js 檔、`scripts/projection.sh`。

### Non-goals（行為層）

- 本 task 不包含員工有效權限合成——`GET /employee-access/permissions/{userId}` 與 gRPC `getPermissions` 行為**完全不變**（角色權限尚不影響任何員工的有效權限）。
- 本 task 不包含 `assign-roles` / `revoke-roles` 的驗證升級（仍接受任意字串，不驗 Role aggregate 存在性；但自本 task 起立下「傳 roleId」的慣例）。
- 本 task 不包含 `role-holders` 的 department/firm 過濾（permission-holders 有此過濾；role-holders v1 先不做，需要時再仿作）。
- 本 task 不包含歷史 `EmployeeAccess.roles` 字串資料的遷移或對映（名稱字串 → roleId）。
- 本 task 不包含前端 UI 實作與 per-role 細粒度授權（沿用 admin token 全有全無守門）。

---

## 驗收標準

### Agent 必做（可機器執行）

前置：KurrentDB 於 `localhost:2113` 運行；標注「需 projection」的 3 個測試另需先部署 projection。

```bash
# 1. 編譯 gate（codegen + 全 target）
swift build

# 2. 契約符號存在（grep 特定 symbol，不用計數）
grep -n "RoleCreated:" Sources/RoleAggregate/event.yaml
grep -n "RolePermissionsAdded:" Sources/RoleAggregate/event.yaml
grep -n "RoleRenamed:" Sources/RoleAggregate/event.yaml
grep -n "kind: deletedEvent" Sources/RoleAggregate/event.yaml
grep -n "operationId: getRolePermissions" Sources/RoleAggregate/openapi.yaml
grep -n "operationId: getRoles" Sources/RoleAggregate/openapi.yaml
grep -n "operationId: getRoleHolders" Sources/EmployeeAccessAggregate/openapi.yaml
grep -n 'name: "RoleAggregate"' Package.swift   # target 宣告存在（依賴/資源/plugin 完整性由 swift build 把關）
grep -n "IAM_GetRoles-all" projections/IAM_GetRolesProjection.js
grep -n "IAM_GetRoleHolders-" projections/IAM_RoleHoldersProjection.js

# 3. 回歸保護：EmployeeAccess 的核心不可動區塊必須零 diff
git diff --stat -- Sources/EmployeeAccessAggregate/Entity \
                   Sources/EmployeeAccessAggregate/Usecase/Port \
                   Sources/EmployeeAccessAggregate/Usecase/Service \
                   Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissions \
                   Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissionHolders \
                   Sources/EmployeeAccessAggregate/event.yaml \
                   Sources/EmployeeAccessAggregate/EmployeeAccessError.swift   # 必須輸出為空
grep -n "operationId: getPermissions" Sources/EmployeeAccessAggregate/openapi.yaml   # 必須仍存在
grep -n "operationId: getPermissionHolders" Sources/EmployeeAccessAggregate/openapi.yaml   # 必須仍存在

# 4. 部署 projection 後跑整合測試
bash scripts/projection.sh
swift test --filter RoleIntegrationTests
```

- [ ] `swift build` 綠（含 codegen plugins）
- [ ] 上列 grep 全數命中；步驟 3 的 `git diff --stat` 輸出為空
- [ ] `swift test --filter RoleIntegrationTests` 全綠（12 個測試）

### Human 補做（需要人類介入）

- [ ] `IAM_ADMIN_API_TOKEN=<token> IAM_GRPC_AUTH_TOKEN=<token> swift run IAMContextServer` 起服務（HTTP 24202；兩個 auth env 未設會 fail-closed 拒絕啟動），變更請求帶 `Authorization: Bearer <token>`，以 curl 走 golden path：`POST /roles` 建角色（拿到 UUID roleId）→ rename → update-description → 批次 add 兩個 catalog 內權限 → `GET /roles/{roleId}/permissions` 見兩筆 → 批次 remove 一筆 → 剩一筆 → `DELETE` → 再查得 404。預期無 5xx。
- [ ] 未帶 `Authorization: Bearer` 打 `POST /roles` → 預期 401（AdminTokenMiddleware 生效於新路由）。
- [ ] 部署 projection 後（`bash scripts/projection.sh`），建立角色 → 1 秒內 `GET /roles` 出現（含 name/description）；改名後清單更新；刪除後消失。
- [ ] 以既有 assign-roles API 指派一個 roleId 給測試員工 → `GET /employee-access/role-holders?role=<roleId>` 出現該 userId；revoke 後消失。
- [ ] KurrentDB 管理介面確認 `IAM_GetRoles-all`、`IAM_GetRoleHolders-<roleId>` stream 有 link 事件、`$ce-IAMRole` category 正常累積。

---

## 已知限制

1. **名稱唯一性是 best-effort**：race window 存在（read model 最終一致），create/rename 幾乎同時的同名寫入可能都成功。嚴格唯一需 reservation pattern，明確 defer；UI 端清單提示可緩解。
2. **`getRoles` / `getRoleHolders` 最終一致**：寫入後清單有 projection lag（數百 ms 級）；且 **projection 未部署時回空清單而非錯誤**——部署（`bash scripts/projection.sh`）是上線前必要人工步驟。
3. **role holders 反查以字串原值分流**：`EmployeeAccess.roles` 仍是自由字串；歷史資料若存的是角色名稱而非 roleId，用 roleId 反查不到。慣例自本 task 起為「assign-roles 傳 roleId」；歷史資料遷移與 assign-roles 驗證升級屬後續 task。刪除仍被持有的角色不會阻擋、也不影響任何人的有效權限（合成不存在）；後續「有效權限合成」task 以 fail-safe deny 處理懸空引用（討論檔 D9）。
4. **no-op 回 422**：rename/update-description/批次淨效果為空時拒絕（沿用 `departmentUnchanged` 精神）；UI 重送（double-click）會看到 422，需視為良性。
5. **[inferred] 待實作首步驗證項**：`PermissionCatalog` 生成符號名與 visibility（Step 0-4）；`POST /roles`（無 path id）與 `DELETE` 動詞在 OpenAPIGenerator 的支援（介面合約 §3a fallback）；`event-generator-config.yaml` 的欄位形狀（見實作回填 #3）。（DDDKit delete 流程已由外部審查對照原始碼確認——`repository.delete` 內部 `markDelete()`——自 inferred 清單移除。）
6. **依賴關係**：無前置 task。後續 task（不阻塞本 task）：有效權限合成、assign-roles 驗證與歷史資料對映、role-holders 過濾、UI。

**修訂 2026-09-24**：`getRoles` read model 追加 `permissions: [String]`（折疊 `RolePermissionsAdded`／`RolePermissionsRemoved`），為後續「員工有效權限合成」與「permission-holders 反查聯集」預留「哪些角色含某權限」的查詢基礎；源自 2026-09-21 設計審查（codex 第二意見）標為 BLOCKER 的項目，詳見 `docs/2026-09-21-role-mechanism-plan.html` 第六、八節。

---

## 實作回填（2026-09-24）

> 本 task 已實作完成、`swift test` 94/94 綠、registry 標 done（未 commit）。以下逐條記錄實作與規格原文的偏差，來源：`phase1-log.md`。正文中被偏離的句子已就地加註「（見實作回填 #n）」。

1. **規格原文（§1 事件表，`RoleDeleted` 列 `aggregateRootId alias: roleId`）→ 實作採用：`RoleDeleted` 事件不帶 `aggregateRootId` alias，形狀與 `EmployeeAccessDeleted` 相同（皆無 alias）→ 理由：`DomainEventGeneratorPlugin` 對 `deletedEvent` 種類的事件若帶 `alias`，會生成違反 DDDKit `DeletedEvent` protocol 要求的 init（Step 0 codegen 階段即發現，屬 build-time 硬限制，非設計選擇）。
   證據：`Sources/RoleAggregate/event.yaml:38-39`（`RoleDeleted: kind: deletedEvent`，其後無 alias 行）；對照 `Sources/EmployeeAccessAggregate/event.yaml:66-67`（`EmployeeAccessDeleted` 同樣無 alias，確認為既有慣例）。

2. **規格原文（改動檔案表 `GetRoleHoldersApplicationService.swift` 說明「無人持有回 `[]`（鏡像 GetPermissionHolders）」；Step 4「無人持有回 `[]`（對照 `GetPermissionHoldersApplicationService`）」；失敗路徑「presenter 無資料 → 回 `[]`……與 `GetPermissionHolders` 的 unknown-permission 行為一致」）→ 實作採用：`GetRolesApplicationService` 與 `GetRoleHoldersApplicationService` 皆改為窄 catch——只把 `DDDError` 且 `code == .eventsNotFound`（read model 尚無事件／projection 未部署）視為空結果，其餘錯誤原樣上拋，由 `ApiHandler` 映射成 `503`；並未照規格字面「鏡像」既有 `GetPermissionHolders` 的 `try?` 吞掉所有錯誤的寫法。
   理由：codex（gpt-5.5）總審第二意見指出，若真的鏡像既有 `try?` 全吞寫法，KurrentDB 不可用時會被吞成 `[]` 而非 `503`，直接違反規格 §4／失敗路徑「KurrentDB 不可用 → 503」的承諾；兩者字面矛盾時，以「失敗路徑必須可靠回 503」為準，「鏡像既有寫法」讓步。既有 `GetPermissionHoldersApplicationService` 本身的同型 `try?`（見已知限制段）不在本 task 範圍，未回頭修改。
   證據：`Sources/RoleAggregate/Adapter/GetRoles/GetRolesApplicationService.swift:38`（`catch let error as DDDError where error.code == .eventsNotFound`）；`Sources/EmployeeAccessAggregate/Adapter/GetRoleHolders/GetRoleHoldersApplicationService.swift:35`（同型窄 catch）；對照既有 `Sources/EmployeeAccessAggregate/Adapter/GetPermissionHolders/GetPermissionHoldersApplicationService.swift:72`（仍是 `try?` 全吞，本 task 未動）。

3. **規格原文（已知限制 #5「`event-generator-config.yaml` 的欄位形狀」列為 `[inferred]` 待驗證項）→ 實作採用：確認 `Sources/RoleAggregate/event-generator-config.yaml` 複製自 `EmployeeAccessAggregate` 同名檔並改 aggregate 名後可正常 codegen；`swift build` 對該檔回報「unhandled resource」warning，比對 `Sources/EmployeeAccessAggregate/event-generator-config.yaml` 同樣觸發相同 warning。
   理由：確認此 warning 是 SwiftPM 對這類資源檔的既有慣例（EmployeeAccessAggregate 早已存在、非本 task 引入的缺陷），故不視為需修正的問題，[inferred] 項就此結案。
   證據：`Sources/RoleAggregate/event-generator-config.yaml`（存在，Step 0 產出）；`Sources/EmployeeAccessAggregate/event-generator-config.yaml`（既有檔，同樣觸發 warning，兩檔並存確認為既有慣例）。
