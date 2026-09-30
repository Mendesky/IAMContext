# 階段二：員工有效權限合成（角色開始影響權限）

## 來源

規劃報告：`docs/2026-09-21-role-mechanism-plan.html`（第五、六、七、八、九節；決策依據見該報告 footer 的驗證與審查回填清單）。
前置：`docs/tasks/role-aggregate.md`（階段一，狀態 `ready`，尚未實作；本 task `depends_on` 它）。

階段一建立 Role aggregate 本體（建立/改名/改描述/加減權限/刪除、`getRoles`、`getRolePermissions`、`getRoleHolders`），但明確把「員工有效權限＝直接授權 ∪ 角色展開」列為 Non-goal，`getPermissions` 行為完全不變。本 task 解除這條 Non-goal：角色的權限開始真正影響 `getPermissions`（HTTP + gRPC 兩個入口）與 `getPermissionHolders` 的反查結果，且**不對任何一位員工寫入事件**——角色改一次，下一次查詢就是新結果。

---

## 目標與 Non-goals

**目標**：

1. 員工只存 roleId（既有行為不變），權限清單只存在 Role。查詢時把「直接授權」與「角色展開」在讀取路徑合成，寫入路徑不互相觸碰。
2. `assignRoles` 開始驗證 roleId 必須指向一個存在且未刪除的 Role，否則拒絕（`roleNotFound`）；`revokeRoles` 不驗證（撤銷不存在的角色引用本就無害，沿用既有行為）。
3. `getPermissionHolders` 與 `getPermissions` 同一版切換——兩者共享同一份角色展開邏輯，避免「有權限卻選不到人」的不一致（`getPermissionHolders` 有外部消費端：OpportunityContext 後端、mendesky-web 選派人 modal）。
4. gRPC 契約（`proto/PermissionsService.proto`）與 `Sources/Generated/` 不變；消費端不需改碼。

**Non-goals（本 task 不做，全部明列於報告第九節「階段三」或第十節）**：

- `getEffectivePermissions`：回傳「直接授權 vs 經由哪個角色」的來源明細。放階段三。
- 懸空 roleId 清理查詢（列出「解析不到的 roleId」供人工清理）。放階段三。
- 消費端快取失效機制（縮短 `CachingPermissionsProvider` 的 TTL，或由 IAM 廣播失效）。報告第五節明確：這是與角色機制獨立的題目，不在本輪，接受現狀（角色編輯與直接授權的生效延遲相同，最多 60 秒）。
- 角色名稱嚴格唯一性（reservation pattern）。role-aggregate.md 已定調 best-effort，本 task 不升級。
- 歷史 `EmployeeAccess.roles` 內非 roleId 舊字串資料的遷移或對映。role-aggregate.md 已知限制 #3 保留，本 task 只保證「解析不到 = 零權限貢獻、不報錯」。
- `getRoleHolders` 的 department/firm 過濾、角色管理前端 UI。role-aggregate.md 與報告階段三範圍，不動。
- RoleAggregate 內部（Entity／Usecase/Port/In／Usecase/Service／event.yaml／openapi.yaml／projection-model.yaml）的任何行為變更——本 task 只在 RoleAggregate target 內**新增**一個 adapter 檔案，不改階段一定義的既有行為。

---

## 介面合約（Interface Contract）

### a. `protocol RoleDirectory`（新增，`Sources/EmployeeAccessAggregate/Usecase/Port/Out/RoleDirectory.swift`）

```swift
import Foundation

/// EmployeeAccessAggregate 對「角色定義」的唯一出埠（outgoing port）。EmployeeAccessAggregate target
/// 不依賴 RoleAggregate target——由 RoleAggregate 端提供實作（見 §b），組裝在 IAMContextServer。
/// 整合測試可注入假的目錄（報告第五節「落地位置」原文）。
package protocol RoleDirectory {  // 見實作回填 #4
    /// 解析一批 roleId 各自的權限集合。查不到或已刪除的 roleId **不出現在結果字典的 key 中**
    /// （不是回空集合值——呼叫端用 `resolved.keys` 判斷「這個 roleId 有效」，見 §e 的 assignRoles 驗證）。
    func resolve(roleIds: Set<String>) async throws -> [String: Set<String>]

    /// 回傳目前仍存在（未刪除）且權限集合包含 `permission` 的所有 roleId。
    /// [inferred] 報告原文只點出 getPermissionHolders 要「用 GetRoles 目錄找出含該權限的角色」，
    /// 沒有明講落在哪個型別。獨立設計理由：GetPermissionHoldersApplicationService 在
    /// EmployeeAccessAggregate target，若直接 import RoleAggregate 的 GetRolesPresenter 會與
    /// 「RoleAggregate → EmployeeAccessAggregate」的既有依賴方向（見 §b）形成 SwiftPM 循環依賴
    /// （target 間不允許環）。把這個查詢也收進同一個 `RoleDirectory` port，兩個方向都維持
    /// 單向依賴，且 §g 仍只需要一個注入點。
    func rolesContaining(permission: String) async throws -> Set<String>
}
```

### b. RoleAggregate 端 adapter（新增，`Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift`）

```swift
import EmployeeAccessAggregate   // 新依賴，見「改動檔案」的 Package.swift 項
import KurrentDB

package struct RoleAggregateDirectory: RoleDirectory {
    private let repository: RoleRepository
    private let kdbClient: KurrentDBClient   // rolesContaining 需要 rehydrate GetRoles 目錄（projection）

    package init(repository: RoleRepository, kdbClient: KurrentDBClient) {  // 見實作回填 #1
        self.repository = repository
        self.kdbClient = kdbClient
    }

    package func resolve(roleIds: Set<String>) async throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for roleId in roleIds {
            // repository.find(byId:) 對不存在／已刪除的 aggregate 回 nil（role-aggregate.md §4）→ 略過。
            guard let role = try await repository.find(byId: roleId) else { continue }
            result[roleId] = role.permissions ?? []
        }
        return result
    }

    package func rolesContaining(permission: String) async throws -> Set<String> {
        // [inferred] role-aggregate.md 只定義 RolesReadModel 的形狀（roles: [{roleId, name,
        // description?, permissions: [String]}]，id 固定 "all"），未定義 GetRolesPresenter 的
        // Input 型別名稱與 GetRolesPresenter.execute 的確切呼叫方式（role-aggregate.md 本身在
        // 已知限制 #5 也把相鄰的 codegen 形狀列為 inferred）。實作第一步須對照階段一實際產出的
        // GetRolesPresenter / GetRolesInput 確認正確用法；下列為預期形狀：
        // presenter.execute 對未部署／空 stream 的 GetRoles projection 可能回 nil，也可能拋錯
        // （鏡像 GetPermissionHoldersApplicationService 既有的 `try?` 處理模式，見該檔案註解：
        // 「presenter.execute 回 nil 或 DDDError.eventsNotFoundInProjector；兩者皆代表持有者為空」）。
        // 這裡必須用 `try?` 吞掉錯誤，不可讓它往外拋——否則 getPermissionHolders 會被拖成 503，
        // 違背下方失敗路徑「projection 未部署回空集合、不報錯」的承諾。
        let presenter = GetRolesPresenter(coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper()))
        guard let readModel = try? await presenter.execute(input: .init())?.readModel else { return [] }  // 見實作回填 #2
        return Set(readModel.roles.filter { $0.permissions.contains(permission) }.map(\.roleId))
    }
}
```

- **一致性差異**：`resolve` 走 aggregate rehydrate（強一致）；`rolesContaining` 走 `$ce-IAMRole` 折疊的 GetRoles projection（最終一致，同 role-aggregate.md 已知限制 #2）。這個差異會反映到 §h 的一致性語意表與 §g 的 getPermissionHolders 行為。
- 若階段一實際產出的符號名稱與上列不同（例如 presenter 建構式簽章、read model 的 nested 型別名），以階段一 build product 為準，本檔的呼叫方式對應調整；核心契約（`RoleDirectory` 的兩個方法簽章）不受影響。

### c. `PermissionsReadModel` 新增 `roles` 欄位（修改）

`Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissions/PermissionsReadModel.swift` 新增：

```swift
package var roles: Set<String> = []
```

- 型別為非 optional（沿用 class 屬性預設值慣例，如既有 `employeeAccessId: String = ""`），不需要改 `init(userId:)`。
- `permissions` 欄位維持既有的 `Array<String>?`，不動——`roles` 是本次新增的第二個折疊目標，兩者語意不同（permissions 是直接授權、roles 是持有的 roleId 集合）互不影響。

### d. `GetPermissionsPresenter` 的 `RolesAssigned` / `RolesRevoked` 從 no-op 改為聯集／差集（修改）

`Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissions/GetPermissionsPresenter.swift`：

```swift
package func when(readModel: inout ReadModelType, event: RolesAssigned) throws {
    readModel.roles.formUnion(event.roles)
}

package func when(readModel: inout ReadModelType, event: RolesRevoked) throws {
    readModel.roles.subtract(event.roles)
}
```

`RolesAssigned.roles` / `RolesRevoked.roles` 型別是 `[String]`（`event.yaml` 既有定義，不改），`Set.formUnion`/`subtract` 接受任意 `Sequence`，直接可用。

### e. `GetPermissionsApplicationService` 新增 `RoleDirectory` 依賴（修改）

`Sources/EmployeeAccessAggregate/Adapter/GetPermissions/GetPermissionsApplicationService.swift`：

```swift
package struct GetPermissionsApplicationService: ApplicationService {
    package typealias Input = GetPermissionsApplicationServiceInput
    package typealias Output = [String]

    private let kdbClient: KurrentDBClient
    private let roleDirectory: RoleDirectory
    package let debugOverridePermissions: [String]?

    package init(kdbClient: KurrentDBClient, roleDirectory: RoleDirectory, debugOverridePermissions: [String]? = nil) {
        self.kdbClient = kdbClient
        self.roleDirectory = roleDirectory
        self.debugOverridePermissions = debugOverridePermissions
    }

    package func execute(input: Input) async throws -> Output {
        if let overrides = debugOverridePermissions {
            return overrides   // debug 模式不變：完全略過角色展開
        }
        let presenter = GetPermissionsPresenter(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
        guard let readModel = try await presenter.execute(input: .init(userId: input.userId))?.readModel else {
            throw ContextError<EmployeeAccessQueryError>(
                error: .notFound,
                in: .struct(GetPermissionsApplicationService.self, function: #function),
                message: "read model not found for \(input.userId)"
            )
        }
        var permissions = Set(readModel.permissions ?? [])
        let roleGrants = try await roleDirectory.resolve(roleIds: readModel.roles)
        for grantedPermissions in roleGrants.values {
            permissions.formUnion(grantedPermissions)
        }
        return Array(permissions)
    }
}
```

- **aggregate 不存在時行為不變**：`readModel == nil` 的 `notFound` guard 在角色展開之前，`roleDirectory` 完全不會被呼叫（沿用 gRPC 端「查不到 = 回空清單」的既有轉換，見 `PermissionsService.getPermissions` 的 catch 分支，本 task 不改該分支）。
- **解析不到的 roleId 貢獻零權限、不報錯**：`roleGrants` 只含 `resolve` 回傳字典裡實際存在的 key，舊字串或已刪除的 roleId 自然不在其中。

### f. `AssignRolesUsecase` 新增 `RoleDirectory` 依賴 + `roleNotFound` 驗證（修改）

`Sources/EmployeeAccessAggregate/Usecase/Port/In/AssignRoles/AssignRolesUsecase.swift`：

```swift
package protocol AssignRolesUsecase: Usecase where Input == AssignRolesInput, Output == AssignRolesOutput {
    var repository: EmployeeAccessRepository { get }
    var roleDirectory: RoleDirectory { get }
}

extension AssignRolesUsecase {
    package func execute(input: AssignRolesInput) async throws -> AssignRolesOutput {
        let requestedRoleIds = Set(input.roles)
        let resolved = try await roleDirectory.resolve(roleIds: requestedRoleIds)
        guard requestedRoleIds.isSubset(of: Set(resolved.keys)) else {
            throw ContextError<EmployeeAccessError>.roleNotFound(function: #function, message: "one or more roleId not found or already deleted")
        }
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            try employeeAccess.assignRoles(employeeAccessId: input.employeeAccessId, userId: input.userId, roles: input.roles)
            try await repository.save(aggregateRoot: employeeAccess, userId: input.operatorId)
            return .init(id: employeeAccess.id, message: nil)
        } catch let error as ContextError<EmployeeAccessError> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
    }
}
```

- 驗證放在 usecase 層（比照 role-aggregate.md D7 的既有精神：驗證放 usecase，不放 aggregate），且在 `repository.find` 之前——不存在的 roleId 不需要先讀 employeeAccess 就能拒絕。
- **`revokeRoles` 不驗證**：`RevokeRolesUsecase`／`RevokeRolesService` 不改，撤銷一個不存在的角色引用本就無害（此為既定範圍，見 Non-goals）。
- 新增 `EmployeeAccessError.roleNotFound` case（`Sources/EmployeeAccessAggregate/EmployeeAccessError.swift`）：

```swift
case roleNotFound  // assignRoles 指到不存在或已刪除的 roleId（Added post-role-permission-composition）

extension ContextError where ErrorType == EmployeeAccessError {
    static func roleNotFound(function: String = #function, message: String = "") -> Self {
        .init(error: .roleNotFound, in: .class(EmployeeAccess.self, function: function), message: message)
    }
}
```

  同步在 `Sources/EmployeeAccessAggregate/openapi.yaml` 的 `EmployeeAccessApiError` enum 加一行 `- roleNotFound`，並在 `Sources/EmployeeAccessAggregate/Adapter/ApiComponents/ApiComponents+EmployeeAccessApiError.swift` 的 `init?(from error: EmployeeAccessError)` 加 `case .roleNotFound: self = .roleNotFound`（照既有 case-by-case 映射慣例，走 422）。

  `AssignRolesService`（`Sources/EmployeeAccessAggregate/Usecase/Service/AssignRolesService.swift`）與 `AssignRolesApplicationService`（`Sources/EmployeeAccessAggregate/Adapter/AssignRoles/AssignRolesApplicationService.swift`）各自新增 `roleDirectory: RoleDirectory` 儲存屬性 + init 參數，並在 Application Service 建構 `AssignRolesService` 時原樣轉傳。

### g. `GetPermissionHoldersApplicationService` 改為聯集（修改）

`Sources/EmployeeAccessAggregate/Adapter/GetPermissionHolders/GetPermissionHoldersApplicationService.swift` 新增 `roleDirectory: RoleDirectory` 依賴；`execute` 邏輯：

```swift
package func execute(input: Input) async throws -> Output {
    // 1. 直接持有者：既有程式碼在 presenter 讀不到 stream（權限從未被直接授予過任何人）時是
    //    `guard let output = try? presenter.execute(...) else { return [] }`——這個 early return
    //    必須拿掉，改成把「讀不到」視為「零位直接持有者」並繼續往下跑角色展開。這是本 task 對
    //    既有邏輯的唯一調整：若照舊保留 early return，權限只被角色持有、無人直接持有時（驗收
    //    測試 #9 的情境）會在這裡就回空清單，角色來源的持有者永遠不會被算進來。
    //    對既有測試無影響：直接持有者為空時，department/firm 過濾套用在空集合上結果同樣是空，
    //    與 early return 的既有結果一致——差異只在「繼續往下跑角色展開」這件事本身。
    let presenter = GetPermissionHoldersPresenter(
        coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
    )
    let directHolders: [String]
    if let output = try? await presenter.execute(input: .init(permission: input.permission)) {  // 見實作回填 #2
        directHolders = output.readModel.userIds
    } else {
        directHolders = []
    }

    // 2. 找出含此權限的角色（見 §a 的 rolesContaining）：
    let roleIds = try await roleDirectory.rolesContaining(permission: input.permission)

    // 3. 每個角色的持有者——用**同一個 target 內**既有的 GetRoleHoldersApplicationService
    //    （role-aggregate.md D16，落在 EmployeeAccessAggregate，無跨 target 依賴問題）：
    var roleHolderIds: Set<String> = []
    for roleId in roleIds {
        // [inferred] GetRoleHoldersApplicationService 的 Input 欄位名稱（`role` 或 `roleId`）
        // role-aggregate.md 只寫「鏡像 GetPermissionHoldersApplicationService」，未逐字定義 Input
        // struct；比照 GetPermissionHoldersApplicationServiceInput.permission 的命名慣例，此處
        // 假設欄位名為 `role`，實作時對照階段一實際產出調整。
        let holders = (try? await GetRoleHoldersApplicationService(kdbClient: kdbClient).execute(input: .init(role: roleId))) ?? []
        roleHolderIds.formUnion(holders)
    }

    // 4. 聯集，department/firm 過濾套用在聯集後的結果上（既有過濾邏輯不變，只是輸入集合從
    //    directHolders 換成 allUserIds）：
    let allUserIds = Array(Set(directHolders).union(roleHolderIds))
    guard input.department != nil || input.firm != nil else { return allUserIds }
    /* 既有的 PermissionScopeFilter 過濾迴圈，改吃 allUserIds 而非 directHolders */
}
```

- **移除 direct-holder 的 early return**：見上方程式碼註解——這是本 task 唯一一處把既有「讀不到 = 立即回空清單」改成「讀不到 = 視為空陣列、繼續往下跑」的地方，目的是讓「只經由角色持有、無人直接持有」的情境可被查到（驗收測試 #9）。
- **成本界線**（報告原文）：過濾是逐人讀 `PermissionsReadModel`，今天的直接持有者路徑已是如此；聯集後人數上限是全公司員工數（數百人），可接受。若日後要更快，再加一支帶部門欄位的 role-holders projection，不改本設計。
- **一致性**：`rolesContaining` 走最終一致的 GetRoles projection，`GetRoleHoldersApplicationService` 走最終一致的 GetRoleHolders projection（role-aggregate.md 既有定義）——`getPermissionHolders` 整體維持既有的「最終一致」語意，不因本次改動變得更差或更好。

### h. 一致性語意表

| 查詢／操作 | 依賴 | 一致性 | 備註 |
|---|---|---|---|
| `getPermissions` 的角色展開（`resolve(roleIds:)`） | Role aggregate rehydrate（`RoleRepository.find(byId:)`） | 強一致 | 角色編輯完成後，下一次查詢立即反映（報告核心賣點） |
| `assignRoles` 的 roleId 存在性驗證（`resolve(roleIds:)`） | 同上 | 強一致 | 指到已刪除或不存在的 roleId 立即拒絕，不會寫入 |
| `getPermissionHolders` 的角色反查（`rolesContaining(permission:)`） | RoleAggregate 的 GetRoles projection（`$ce-IAMRole` 折疊） | 最終一致（projection lag，數百 ms 級，同 role-aggregate.md 已知限制 #2） | 角色權限剛異動後，短暫窗口內 `getPermissionHolders` 的角色來源那一半可能還沒反映；projection 未部署時回空集合（不報錯），退化為只看得到直接持有者 |
| 員工「持有哪些 roleId」（`GetPermissionsPresenter` 折疊 `RolesAssigned`/`RolesRevoked`） | 既有 `IAM_GetPermissions-<userId>` projection | 既有延遲，本 task 不改 | 與直接授權（`PrivilegeGranted`/`PrivilegeRevoked`）的延遲相同 |
| `getRoleHolders`（角色→持有者，供 §g 使用） | EmployeeAccessAggregate 的 GetRoleHoldersPresenter（`$ce-IAMEmployeeAccess` 折疊，role-aggregate.md D16） | 最終一致 | 沿用階段一既有定義，本 task 不改 |
| 消費端快取 | Middleware `CachingPermissionsProvider` | 60 秒 TTL（正結果）/10 秒（空結果），既有行為 | 不在本 task 範圍；角色編輯的生效延遲與直接授權相同，見報告第五節 |

---

## 改動檔案

### 新增

| 檔案 | 說明 |
|---|---|
| `Sources/EmployeeAccessAggregate/Usecase/Port/Out/RoleDirectory.swift` | `protocol RoleDirectory`（介面合約 §a） |
| `Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift` | `RoleDirectory` 的生產實作（介面合約 §b） |
| `Tests/IAMContextTests/FakeRoleDirectory.swift` | 測試用假 `RoleDirectory`（見驗收標準前的「測試基礎設施」說明） |
| `Tests/IAMContextTests/RolePermissionCompositionIntegrationTests.swift` | 階段二整合測試（9 條，見驗收標準） |

### 修改

| 檔案 | 改動描述 |
|---|---|
| `Package.swift` | `RoleAggregate` target 的 `dependencies` 新增 `.target(name: "EmployeeAccessAggregate")`（`RoleAggregateDirectory` 需要 import 才能實作 `RoleDirectory`）。`IAMContextServer`／`IAMContextTests` 對 `RoleAggregate` 的依賴已由階段一加入，本 task 不重複加 |
| `Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissions/PermissionsReadModel.swift` | 新增 `roles: Set<String> = []`（介面合約 §c） |
| `Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissions/GetPermissionsPresenter.swift` | `when(RolesAssigned)`／`when(RolesRevoked)` 由 no-op 改聯集／差集（介面合約 §d） |
| `Sources/EmployeeAccessAggregate/Adapter/GetPermissions/GetPermissionsApplicationService.swift` | 新增 `roleDirectory` 依賴 + 聯集邏輯（介面合約 §e） |
| `Sources/EmployeeAccessAggregate/Usecase/Port/In/AssignRoles/AssignRolesUsecase.swift` | 協定新增 `roleDirectory` 要求 + 預設實作加驗證（介面合約 §f） |
| `Sources/EmployeeAccessAggregate/Usecase/Service/AssignRolesService.swift` | 新增 `roleDirectory` 儲存屬性 + init 參數 |
| `Sources/EmployeeAccessAggregate/Adapter/AssignRoles/AssignRolesApplicationService.swift` | 新增 `roleDirectory` 參數並轉傳給 `AssignRolesService` |
| `Sources/EmployeeAccessAggregate/EmployeeAccessError.swift` | 新增 `case roleNotFound` + `ContextError` factory（介面合約 §f） |
| `Sources/EmployeeAccessAggregate/openapi.yaml` | `EmployeeAccessApiError` enum 新增 `roleNotFound` 一行 |
| `Sources/EmployeeAccessAggregate/Adapter/ApiComponents/ApiComponents+EmployeeAccessApiError.swift` | `init?(from error:)` 新增 `roleNotFound` 映射 |
| `Sources/EmployeeAccessAggregate/Adapter/GetPermissionHolders/GetPermissionHoldersApplicationService.swift` | 新增 `roleDirectory` 依賴 + 聯集邏輯（介面合約 §g） |
| `Sources/EmployeeAccessAggregate/Adapter/ApiHandler.swift` | init 新增 `roleDirectory` 儲存屬性；`getPermissions`／`assignRoles`／`getPermissionHolders` 三個 handler 建構對應 Application Service 時多傳 `roleDirectory`（其餘 handler 不動） |
| `Sources/IAMContextServer/PermissionsService.swift` | init 新增 `roleDirectory` 儲存屬性；`getPermissions` 建構 `GetPermissionsApplicationService` 時多傳 `roleDirectory` |
| `Sources/IAMContextServer/IAMContextServer.swift` | 組裝一個 `RoleAggregateDirectory`（`RoleRepository` + `kdbClient`），同一個實例傳給 `EmployeeAccessAggregate.ApiHandler(...)` 與 `PermissionsService(...)` 兩處建構式。**只改一邊即為未完成**：兩個入口若沒有同時接上同一個 `roleDirectory` 實例，就會出現「HTTP 有角色權限、gRPC 沒有」（或反之）的不一致 |

### 既有測試呼叫點連帶更新（不是新行為，只是建構式簽章多一個必填參數）

`RoleDirectory` 不給預設值（`resolve`/`rolesContaining` 是核心行為，給空預設會讓 `assignRoles` 對任何角色都拒絕，等於默默改變既有測試的語意）。以下既有測試檔案在建構受影響型別時，一律多傳 `roleDirectory: FakeRoleDirectory()`（預設建構：見下方測試基礎設施說明，對任何 roleId 都視為存在、不影響既有斷言；下表漏列一筆呼叫點，見實作回填 #5）：

| 檔案 | 受影響建構式呼叫 |
|---|---|
| `Tests/IAMContextTests/GetPermissionsIntegrationTests.swift` | `GetPermissionsApplicationService(kdbClient:)` ×1、`PermissionsService(kdbClient:)` ×1 |
| `Tests/IAMContextTests/DebugFullPermissionsTests.swift` | `GetPermissionsApplicationService(kdbClient:debugOverridePermissions:)` ×3、`PermissionsService(kdbClient:debugConfig:)` ×2 |
| `Tests/IAMContextTests/GetPermissionHoldersIntegrationTests.swift` | `GetPermissionHoldersApplicationService(kdbClient:)` ×8 |
| `Tests/IAMContextTests/AssignRolesIntegrationTests.swift` | `AssignRolesService(repository:)` ×3 |
| `Tests/IAMContextTests/RevokeRolesIntegrationTests.swift` | `AssignRolesService(repository:)` ×1（用作 seed fixture） |

**測試基礎設施**（`Tests/IAMContextTests/FakeRoleDirectory.swift`，新增）：

```swift
import EmployeeAccessAggregate

/// 測試用假 RoleDirectory。
/// - `resolved == nil`（預設，permissive 模式）：任何 roleId 都視為存在，回傳一個以自己命名的哨兵權限
///   （`"__fake_permission_from_<roleId>__"`）——只保證 assignRoles 的存在性驗證通過，
///   不代表真實權限展開；既有測試（AssignRoles/RevokeRoles/GetPermissions/GetPermissionHolders）
///   都不斷言角色展開出的具體權限，用預設值即可維持原行為。
/// - `resolved` 給定字典：切成「顯式模式」，只有字典裡的 key 視為存在（可模擬「角色不存在」——
///   傳空字典）；測角色具體貢獻的權限也用這個模式。
/// - `containing`：`rolesContaining(permission:)` 的查詢表，預設空字典（等同「沒有任何角色含此權限」），
///   讓不測角色反查的既有 8 個 GetPermissionHolders 測試維持原行為。
package struct FakeRoleDirectory: RoleDirectory {
    private let resolved: [String: Set<String>]?
    private let containing: [String: Set<String>]

    package init(resolved: [String: Set<String>]? = nil, containing: [String: Set<String>] = [:]) {
        self.resolved = resolved
        self.containing = containing
    }

    package func resolve(roleIds: Set<String>) async throws -> [String: Set<String>] {
        if let resolved {
            return resolved.filter { roleIds.contains($0.key) }
        }
        return Dictionary(uniqueKeysWithValues: roleIds.map { ($0, ["__fake_permission_from_\($0)__"]) })
    }

    package func rolesContaining(permission: String) async throws -> Set<String> {
        containing[permission] ?? []
    }
}
```

### 受影響呼叫端（不需修改，列出供 review）

- `OpportunityContext/Sources/OpportunityContext/IAMClient/IAMHTTPPermissionHoldersClient.swift`、`mendesky-web/src/app/features/quoting-cases/components/select-allocator-modal/select-allocator-modal.component.ts`——都吃 `GET /employee-access/permission-holders`，HTTP 回應形狀不變（仍是 `[String]`），行為變化只在「回傳的清單變多了角色來源的人」，不需要改碼。人工驗證見驗收標準的 Human 補做。
- `Middleware/Sources/Middleware/PermissionAuthorization/{PermissionMiddleware,CachingPermissionsProvider}.swift`、`AuditContext/Sources/AuditContextServer/main.swift`——gRPC `getPermissions` 回應形狀不變，快取層無感知，不需改碼。

---

## 實作步驟

### Step 0：確認階段一產出（前置）

1. 確認 `docs/tasks/role-aggregate.md` 已實作完成、`swift test --filter RoleIntegrationTests` 綠——本 task 的 `depends_on` 前提。
2. `swift build` 一次，記下實際產出的 `RoleRepository`、`Role`、`GetRolesPresenter`、`RolesReadModel`（及其 nested 型別）、`RoleAggregateEventMapper` 的確切簽章，核對介面合約 §b 標記 `[inferred]` 的部分，落差就地修正（不改變 §a 的 port 契約）。

### Step 1：新增 `RoleDirectory` port（EmployeeAccessAggregate 側，零依賴新增）

1. 建立 `Sources/EmployeeAccessAggregate/Usecase/Port/Out/RoleDirectory.swift`（介面合約 §a）。
2. `swift build`——此步只新增一個獨立協定檔，不影響既有型別，必須維持全綠。

### Step 2：`Package.swift` 加依賴

1. `RoleAggregate` target 的 `dependencies` 加 `.target(name: "EmployeeAccessAggregate")`。
2. `swift build`——確認新依賴不引入循環（`EmployeeAccessAggregate` 不得反向依賴 `RoleAggregate`，`swift build` 若真的成環會直接報錯）。

### Step 3：RoleAggregate 端 adapter

1. 建立 `Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift`（介面合約 §b），對照 Step 0 記下的實際符號調整。
2. `swift build` 綠，`RoleAggregateDirectory` 型別檢查通過（此時尚未被任何人使用，只求編譯通過）。

### Step 4：`PermissionsReadModel` + `GetPermissionsPresenter`

1. `PermissionsReadModel` 新增 `roles: Set<String> = []`（介面合約 §c）。
2. `GetPermissionsPresenter` 的 `when(RolesAssigned)`／`when(RolesRevoked)` 改實作（介面合約 §d）。
3. `swift build` 綠。

### Step 5：`GetPermissionsApplicationService` + 兩個入口注入

1. `GetPermissionsApplicationService` 加 `roleDirectory` 依賴（介面合約 §e）——此時會編譯失敗，因為呼叫端還沒補參數，屬預期。
2. `ApiHandler` 加 `roleDirectory` 儲存屬性 + init 參數；`getPermissions` handler 建構時多傳。
3. `PermissionsService`（gRPC）同樣加 `roleDirectory` 儲存屬性 + init 參數；`getPermissions` 方法建構時多傳。
4. `IAMContextServer.swift` 組裝 `RoleAggregateDirectory` 並傳入上述兩處建構式（同一個實例）。
5. 補齊「既有測試呼叫點連帶更新」表列的 5 個測試檔（先建立 `FakeRoleDirectory.swift`）。
6. `swift build` 且 `swift test --filter GetPermissionsIntegrationTests` `--filter DebugFullPermissionsTests` 綠——這一步驗證「換了依賴但既有行為不變」。

### Step 6：`AssignRolesUsecase` 驗證 + `roleNotFound`

1. `EmployeeAccessError` 加 `roleNotFound` case + factory；`openapi.yaml` 加 enum 值；`ApiComponents+EmployeeAccessApiError.swift` 加映射（介面合約 §f）。
2. `AssignRolesUsecase` 協定 + 預設實作、`AssignRolesService`、`AssignRolesApplicationService` 三處加 `roleDirectory`（介面合約 §f）。
3. `ApiHandler.assignRoles` 建構 `AssignRolesApplicationService` 時多傳 `roleDirectory`。
4. 補齊 `AssignRolesIntegrationTests.swift`、`RevokeRolesIntegrationTests.swift` 兩個測試檔的呼叫點。
5. `swift build` 且 `swift test --filter AssignRolesIntegrationTests` `--filter RevokeRolesIntegrationTests` 綠。

### Step 7：`GetPermissionHoldersApplicationService` 聯集

1. 加 `roleDirectory` 依賴 + 聯集邏輯（介面合約 §g）。
2. `ApiHandler.getPermissionHolders` 建構時多傳 `roleDirectory`。
3. 補齊 `GetPermissionHoldersIntegrationTests.swift` 的 8 個呼叫點。
4. `swift build` 且 `swift test --filter GetPermissionHoldersIntegrationTests` 綠。

### Step 8：階段二整合測試

1. `Tests/IAMContextTests/RolePermissionCompositionIntegrationTests.swift`，9 條測試（見驗收標準）。組織對照 `AssignRolesIntegrationTests`／`GetPermissionHoldersIntegrationTests`：`@Suite(.serialized)`、直連 `KurrentDB localhost`、`withTestBundle` id 隔離。
2. 需要真實 Role aggregate 的測試（createRole → addPermissions → assignRoles）走階段一的 `CreateRoleService`／`AddPermissionsService`，注入生產路徑的 `RoleAggregateDirectory`（不是 `FakeRoleDirectory`）——這批測試驗的正是「階段一 + 階段二串起來」，用 fake 會測不到真實整合。
3. 需要模擬「roleId 不存在」／「舊字串引用」的測試，用 `FakeRoleDirectory(resolved: [:])`。
4. `bash scripts/projection.sh`（部署 `IAM_GetRolesProjection.js`、`IAM_RoleHoldersProjection.js`——階段一產物，本 task 不新增 projection 檔）。
5. `swift test --filter RolePermissionCompositionIntegrationTests` 全綠。

---

## 失敗路徑

- **`assignRoles` 帶不存在或已刪除的 roleId**：`roleDirectory.resolve` 回傳的字典缺該 key → `roleNotFound` → `422`。可恢復。
- **`getPermissions` 對應的員工不存在**：沿用既有行為不變——`notFound`（HTTP `404`）／gRPC 轉空清單，`roleDirectory` 完全不被呼叫。
- **Role aggregate 所在的 KurrentDB 不可用**：`roleDirectory.resolve`／`rolesContaining` 拋出非 domain error，沿用 `ApiHandler`／`PermissionsService` 既有的 catch-all 分支，落到 `503 serviceUnavailable`（gRPC 對應既有 `.aborted`）——不需要新增例外處理程式碼，既有分支自然涵蓋。
- **手動寫入舊字串（非 roleId）到 `RolesAssigned`**：`resolve` 對該字串找不到對應 Role → 不出現在結果字典 → 貢獻零權限。`getPermissions` 不報錯、不多權限（對應階段二測試 #7）。
- **`getPermissionHolders` 呼叫時 RoleAggregate 的 GetRoles projection 尚未部署**：`rolesContaining` 回空集合（鏡像 role-aggregate.md 已知限制 #2：projection 未部署回空清單而非錯誤），`getPermissionHolders` 退化為只看得到直接持有者，不報錯、不 5xx。記入已知限制。
- **`addPermissions`／`removePermissions` 在階段一已定義的驗證**（`invalidPermission`、`permissionsUnchanged` 等）：不變，本 task 不觸碰 RoleAggregate 內部命令路徑。

---

## 不改動的部分

- **RoleAggregate 內部**（`Entity/`、`Usecase/Port/In/`、`Usecase/Service/`、`event.yaml`、`openapi.yaml`、`projection-model.yaml`、`RoleError.swift`）——本 task 只在 `Sources/RoleAggregate/Adapter/RoleDirectory/` 新增一個檔案，`Package.swift` 只新增一行依賴宣告。
- **`EmployeeAccess` 的事件定義**（`event.yaml`）——`RolesAssigned`／`RolesRevoked` 早已存在（階段零），本 task 只改「怎麼折疊它們」（`GetPermissionsPresenter`），不改事件 schema，也不改 `EmployeeAccess+AssignRoles.swift`／`EmployeeAccess+RevokeRoles.swift` 的 `when(event:)` 狀態轉換（仍是純字串聯集/差集，不驗證 roleId 存在性——存在性驗證在 usecase 層，介面合約 §f）。
- **gRPC 契約**（`proto/PermissionsService.proto`、`Sources/Generated/`）——請求/回應形狀不變，只是 server 端內部多做一層合成。
- **`PermissionScopeFilter`**（department/firm 過濾邏輯本身）——不改，只是套用範圍從「直接持有者」擴大成「聯集後的持有者」。
- **Middleware（`CachingPermissionsProvider` 等）與消費端**——快取行為維持現狀，見報告第五節「消費端生效延遲」；`AdminTokenMiddleware`／`BearerTokenServerInterceptor` 不動。
- **`docs/tasks/role-aggregate.md` 本身**——本檔不修改該規格；階段一與階段二是兩份獨立文件，registry 用 `depends_on` 表達順序。

---

## 驗收標準

### Agent 必做（可機器執行）

前置：階段一已實作完成且 `RoleIntegrationTests` 全綠；KurrentDB 於 `localhost:2113` 運行；`IAM_GetRolesProjection.js`／`IAM_RoleHoldersProjection.js` 已部署。

```bash
# 1. 編譯 gate
swift build

# 2. 契約符號存在
grep -n "protocol RoleDirectory" Sources/EmployeeAccessAggregate/Usecase/Port/Out/RoleDirectory.swift
grep -n "func resolve(roleIds:" Sources/EmployeeAccessAggregate/Usecase/Port/Out/RoleDirectory.swift
grep -n "func rolesContaining(permission:" Sources/EmployeeAccessAggregate/Usecase/Port/Out/RoleDirectory.swift
grep -n "struct RoleAggregateDirectory" Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift
grep -n "var roles: Set<String>" Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissions/PermissionsReadModel.swift
grep -n "case roleNotFound" Sources/EmployeeAccessAggregate/EmployeeAccessError.swift
grep -n "roleNotFound" Sources/EmployeeAccessAggregate/openapi.yaml
grep -n "roleDirectory" Sources/EmployeeAccessAggregate/Adapter/ApiHandler.swift
grep -n "roleDirectory" Sources/IAMContextServer/PermissionsService.swift
grep -n "RoleAggregateDirectory(" Sources/IAMContextServer/IAMContextServer.swift
sed -n '/name: "RoleAggregate",/,/^        ),$/p' Package.swift | grep -n '.target(name: "EmployeeAccessAggregate")'
# 上面 sed 先擷取 RoleAggregate target 的宣告區塊（從 name 到該 .target(...) 收尾的 `),`），
# 再確認區塊內含這筆依賴——不可用全檔計數：Package.swift 既有 IAMContextServer、MigrateFirmFormat
# 等 target 本來就已經依賴 EmployeeAccessAggregate，用「命中次數門檻」在沒有真的替
# RoleAggregate 加上新依賴時也會命中，會誤判通過。

# 3. 回歸保護：proto 與 EmployeeAccess 事件定義零 diff
git diff --stat -- proto/ Sources/Generated/ Sources/EmployeeAccessAggregate/event.yaml \
                   Sources/RoleAggregate/Entity Sources/RoleAggregate/Usecase/Port \
                   Sources/RoleAggregate/Usecase/Service Sources/RoleAggregate/event.yaml \
                   Sources/RoleAggregate/openapi.yaml Sources/RoleAggregate/RoleError.swift
                   # 必須輸出為空

# 4. 整合測試
bash scripts/projection.sh
swift test --filter GetPermissionsIntegrationTests
swift test --filter DebugFullPermissionsTests
swift test --filter AssignRolesIntegrationTests
swift test --filter RevokeRolesIntegrationTests
swift test --filter GetPermissionHoldersIntegrationTests
swift test --filter RolePermissionCompositionIntegrationTests
```

- [ ] `swift build` 綠
- [ ] 上列 grep 全數命中；步驟 3 的 `git diff --stat` 輸出為空
- [ ] 既有 5 個受影響測試檔全綠（證明「換依賴、行為不變」）
- [ ] `RolePermissionCompositionIntegrationTests` 全綠（9 個測試，見下方清單）

**`RolePermissionCompositionIntegrationTests` 的 9 條測試**（直接採用規劃報告第九節階段二清單，命名比照既有 `*IntegrationTests.swift` 慣例）：

| # | 測試 | 對應報告條目 |
|---|---|---|
| 1 | `create_role_add_permissions_assign_reflects_in_both_http_and_grpc`（**兩入口**：同一組資料分別打 `ApiHandler.getPermissions(_:)` 與 `@testable import IAMContextServer` 後直接呼叫 `PermissionsService.getPermissions(request:context:)`，兩者都含該權限；gRPC 呼叫方式比照 `Tests/IAMContextTests/GetPermissionsIntegrationTests.swift` 的 `PermissionsService(...)` 直呼模式，不另起真實 gRPC server） | 條目 1 |
| 2 | `remove_permission_from_role_with_two_holders_reflects_immediately_with_zero_fanout`（**零扇出**：兩位以上員工持有同一角色，`removePermissions` 後兩個入口立即都不含該權限，不 sleep、不重啟；且比較 `$ce-IAMEmployeeAccess` 類別 stream 的事件數在角色編輯前後完全相同——用 `kdbClient` 讀 `$ce-IAMEmployeeAccess` 的事件數量，比對操作前後一致；見實作回填 #3） | 條目 2 |
| 3 | `delete_role_removes_its_permissions_but_direct_grant_remains` | 條目 3 |
| 4 | `permission_from_both_direct_grant_and_role_remains_after_role_removes_it` | 條目 4 |
| 5 | `permission_shared_by_two_roles_remains_after_removing_from_one` | 条目 5 |
| 6 | `assign_roles_with_unknown_roleId_throws_roleNotFound`（用 `FakeRoleDirectory(resolved: [:])` 或指向從未建立的 roleId） | 條目 6 |
| 7 | `legacy_role_string_in_rolesAssigned_contributes_zero_permissions_without_error`（手動用 repository 寫入帶舊字串的 `RolesAssigned`，`getPermissions` 不報錯、不多權限） | 條目 7 |
| 8 | `injected_fake_role_directory_is_used_by_both_http_and_grpc_entrypoints`（分別建構 `ApiHandler(kdbClient:roleDirectory: fake:...)` 與 `PermissionsService(kdbClient:roleDirectory: fake:...)`，證明兩個注入點都真的接上同一份假目錄——與 #1 的差異是這條專測「注入生效」，不測真實 Role aggregate） | 條目 8 |
| 9 | `get_permission_holders_via_role_only_reflects_role_membership_with_department_filter`（某人只經由角色持有權限 p，`getPermissionHolders(p)` 列出他；從角色移除 p 後不再列出；帶 department 過濾時結果一致） | 條目 9 |

### Human 補做（需要人類介入）

- [ ] 起服務（`IAM_ADMIN_API_TOKEN=<token> IAM_GRPC_AUTH_TOKEN=<token> swift run IAMContextServer`），走 golden path：`POST /roles` 建角色 → `add-permissions` 加一個 catalog 內權限 → `POST /employee-access/{id}/assign-roles` 指派給一個測試員工 → `GET /employee-access/permissions/{userId}` 見到該權限 → 用 gRPC client（或既有 debug 工具）打 `getPermissions` 見到同一個權限。
- [ ] 對角色 `remove-permissions` 該權限 → 立即（不等 60 秒快取，直接查 IAM 本身而非經 Middleware 快取）再查 HTTP 與 gRPC，兩者都不再含該權限。
- [ ] `assignRoles` 帶一個從未建立過的 roleId → 預期 `422 roleNotFound`。
- [ ] `DELETE /roles/{roleId}` 刪除一個仍被持有的角色 → 該角色權限從持有者的有效權限消失，其他直接授權的權限不受影響。
- [ ] 找一個只經由角色持有某權限的測試員工，打 `GET /employee-access/permission-holders?permission=<p>` 見到他；把他從角色移除或該角色移除該權限後，再查不再出現。
- [ ] **跨 repo 冒煙測試**（本 task 唯一涉及外部消費端的改動）：以測試資料在 OpportunityContext 本機環境或 mendesky-web 選派人 modal 走一次「角色貢獻的權限可選派到人」，確認 `getPermissionHolders` 語意變化沒有讓既有前端流程壞掉（HTTP 回應形狀不變，理論上不需改碼，但屬外部 repo，agent 驗收管不到，需人工確認一次）。

---

## 已知限制

1. **`getPermissionHolders` 的角色反查是最終一致**：`rolesContaining` 走 GetRoles projection，角色權限剛異動後有短暫 lag（同 role-aggregate.md 已知限制 #2 的量級，數百 ms）。`getPermissions` 本身（含 roleId → 權限的展開）是強一致，兩者不對稱：`getPermissions` 立即反映角色變更，`getPermissionHolders` 的角色來源那一半有 projection 延遲。
2. **消費端仍有 60 秒快取**：IAM 這一端角色改完立即生效，但 Middleware 的 `CachingPermissionsProvider` 讓下游 context 最多再晚 60 秒看到。與直接授權的既有行為一致，本 task 不處理（見 Non-goals）。
3. **舊字串 `roles` 資料仍是惰性引用**：非 roleId 的歷史字串解析不到，貢獻零權限，不報錯，也不在本 task 提供清理工具（階段三）。
4. **`rolesContaining` 的實作依賴階段一 GetRoles read model 的內部形狀（`[inferred]`）**：若階段一實際產出與介面合約 §b 假設的型別/欄位名稱不同，需要在 Step 0/Step 3 對照調整；`RoleDirectory` 的對外契約（§a 的兩個方法簽章）不受影響，呼叫端（e/f/g）不需要跟著改。
5. **`GetRoleHoldersApplicationService` 的 Input 欄位名稱是 `[inferred]`**（§g）：假設為 `role`，需在 Step 7 對照階段一實際產出確認；若欄位名不同，只影響 `GetPermissionHoldersApplicationService` 內部一行呼叫，不影響對外行為。
6. **依賴關係**：`depends_on: ["role-aggregate"]`——階段一必須先實作完成（`RoleIntegrationTests` 全綠）才能開始本 task。後續 task（不阻塞本 task）：`getEffectivePermissions` 明細、懸空 roleId 清理查詢、消費端快取失效機制、角色名稱嚴格唯一性、前端管理 UI（階段三）。
7. **`getRoles` read model 已含 permissions（依 2026-09-24 修正後的 role-aggregate.md）**：規劃報告 §8 原文描述「既有規格的 getRoles read model 只回 roleId/name/description」，但 `docs/tasks/role-aggregate.md` 已於 2026-09-24 依該報告的設計審查（BLOCKER 項）修正——`RolesReadModel`／`GetRolesPresenter` 現在會折疊 `RolePermissionsAdded`/`RolePermissionsRemoved`，`GetRoles` 回應形狀是 `roles: [{roleId, name, description?, permissions: [String]}]`（見 role-aggregate.md「改動檔案」表與檔尾「修訂 2026-09-24」註記）。本規格的 §a/§b/§g（`rolesContaining` 與其呼叫端）直接沿用這個已含 permissions 的 read model，不需要對階段一提出額外變更。

---

## 實作回填（2026-09-24）

> 本 task 已實作完成、`swift test` 103/103 綠、registry 標 done（未 commit）。以下逐條記錄實作與規格原文的偏差，來源：`phase2-log.md`。正文中被偏離之處已就地加註「（見實作回填 #n）」（code block 內以行尾註解形式標記，維持程式碼可讀性）。

1. **規格原文（§b 程式碼範例：`package init(repository: RoleRepository, kdbClient: KurrentDBClient) { self.repository = repository; self.kdbClient = kdbClient }`）→ 實作採用：`RoleAggregateDirectory` 只儲存 `kdbClient: KurrentDBClient`，`init(kdbClient:)` 單一參數；`repository` 改為每次呼叫時建立的 computed property（`private var repository: RoleRepository { .init(coordinator: ...) }`），不再是 stored property。
   理由：`RoleAggregateDirectory` 要能跨 actor（`PermissionsService`，gRPC 端）持有並傳遞，必須維持 `Sendable`；`KurrentStorageCoordinator`／`RoleRepository` 內部持有的型別不是 `Sendable`，存成 stored property 會讓整個 struct 失去 `Sendable`。做法對照既有 `ApiHandler` 的 `repository` computed property 同一模式（只存 `kdbClient`，每次呼叫現建 repository）。
   證據：`Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift:15-24`（`struct RoleAggregateDirectory` 只有 `private let kdbClient`、`init(kdbClient:)`、`private var repository: RoleRepository { ... }` computed property，第 12-14 行註解明文寫出 Sendable 理由）。

2. **規格原文（§b 程式碼註解「這裡必須用 `try?` 吞掉錯誤，不可讓它往外拋」＋ `guard let readModel = try? await presenter.execute(...)` ／ §g 程式碼「`if let output = try? await presenter.execute(...)`」）→ 實作採用：`rolesContaining`（RoleAggregate 端）與 `GetPermissionHoldersApplicationService` 的直接持有者讀取，皆改為窄 catch——只把 `DDDError` 且 `code == .eventsNotFound` 視為空結果，其餘錯誤上拋（沿用 role-aggregate.md 階段一 `GetRoles`／`GetRoleHolders` application service 同一寫法，見該規格實作回填 #2），不是規格字面的 `try?` 全吞。
   理由：與階段一同一組矛盾——`try?` 全吞會讓 KurrentDB 真正不可用時被誤判為「projection 未部署」而回空集合，而非規格失敗路徑要求的 `503`；窄 catch 才能同時滿足「projection 未部署回空集合」與「KDB 不可用回 503」兩條互斥的失敗路徑承諾。
   證據：`Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift:37-47`（`rolesContaining` 內 `catch let error as DDDError where error.code == .eventsNotFound`）；`Sources/EmployeeAccessAggregate/Adapter/GetPermissionHolders/GetPermissionHoldersApplicationService.swift:42-46`（直接持有者讀取同型窄 catch；注意同檔 `:72` 的 department/firm 過濾迴圈仍是既有 `try?`，那是另一段既有邏輯、非本次改動範圍，未變更）。

3. **規格原文（測試 #2 `remove_permission_from_role_with_two_holders_reflects_immediately_with_zero_fanout` 描述「比較 `$ce-IAMEmployeeAccess` 類別 stream 的事件數在角色編輯前後完全相同」）→ 實作採用：零扇出驗證改為比較「各持有者 `EmployeeAccess` aggregate 的 `metadata.version`」在角色編輯操作前後是否相同，而非比較 `$ce-IAMEmployeeAccess` 類別 stream 的事件總數。
   理由：`swift test` 全套執行時多個測試 suite 會並行對 `$ce-IAMEmployeeAccess` 寫入事件（各自的員工 fixture），類別 stream 的事件總數在此期間本就會被其他 suite 改變，用計數比對會產生與本測試邏輯無關的 flaky 失敗；改比較「各持有者自己的 aggregate 版本號」則只反映該員工自身 stream 是否被寫入，不受其他 suite 並行寫入影響。
   證據：`Tests/IAMContextTests/RolePermissionCompositionIntegrationTests.swift:54`（測試函式）、`:300`（註解「各 EmployeeAccess stream 的目前版本（rehydrate 後 metadata.version）。角色編輯前後必須相同＝零扇出。」）、`:305`（`versions[id] = aggregate.metadata.version`）。

4. **規格原文（§a 程式碼範例：`package protocol RoleDirectory { ... }`，未宣告 `Sendable`）→ 實作採用：`package protocol RoleDirectory: Sendable { ... }`。
   理由：`RoleDirectory` 的生產實作（`RoleAggregateDirectory`）與測試替身（`FakeRoleDirectory`）都需要跨 actor 邊界傳遞並被 `ApiHandler`／`PermissionsService`（gRPC）兩處長期持有；協定不宣告 `Sendable`，符合條件的具體型別雖仍可各自標 `Sendable`，但呼叫端把 `any RoleDirectory` 存成跨 actor 的屬性時會在型別系統層級拿不到 Sendable 保證，故直接把約束提升到協定本身。
   證據：`Sources/EmployeeAccessAggregate/Usecase/Port/Out/RoleDirectory.swift:8`（`package protocol RoleDirectory: Sendable {`）。

5. **規格原文（「既有測試呼叫點連帶更新」表，列出 5 個檔案的受影響建構式呼叫，未列 `Tests/IAMContextTests/RoleIntegrationTests.swift`）→ 實作採用：該表之外，額外更新了 `Tests/IAMContextTests/RoleIntegrationTests.swift:272` 的 `AssignRolesService(repository:)` 呼叫點，補上 `roleDirectory: FakeRoleDirectory()` 參數。
   理由：`RoleIntegrationTests.swift` 內也有一處直接建構 `AssignRolesService(repository:)` 作為測試 fixture（指派角色用），簽章同樣因本 task 新增 `roleDirectory` 必填參數而不再編譯；規格表格漏列此呼叫點屬規格盤點疏漏，實作時一併補上，行為與其餘 5 個檔案相同（傳 `FakeRoleDirectory()` 保持既有語意不變）。
   證據：`Tests/IAMContextTests/RoleIntegrationTests.swift:272`（`AssignRolesService(repository: employeeAccessRepository, roleDirectory: FakeRoleDirectory()).execute(...)`）。
