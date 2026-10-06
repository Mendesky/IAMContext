# 員工有效權限時間軸重播（可對個人移除來自角色的權限）

## 來源

討論：`docs/discussions/2026-09-30-permission-timeline-composition.md`（D1–D8 皆經使用者 2026-09-30 逐條確認；取捨不明處以 `[inferred]` 標示並在該檔「開放問題」列出理由）。
前置：`docs/tasks/role-permission-composition.md`（階段二，已實作、狀態 `done`；本 task `depends_on` 它）。

階段二把有效權限定為「直接授權 ∪ 角色**當下**內容」（該規格 §e、§g）。這個模型無法表達「對單一員工移除某個權限、即使它來自角色」——權限只要還在角色裡，聯集就會把它補回來。本 task 把有效權限改為**依時間順序重播**：把該員工的事件與他持有過的每個角色的事件併成一條時間軸，依 KurrentDB 全域位置排序，逐事件更新有效權限集合。對個人的移除就是時間軸上的一個普通事件（沿用既有 `PrivilegeRevoked`），之後發生的事件自然把權限給回來。同一組規則也讓 `revokePrivilege` 與 `grantPrivilege` 的前置條件改看有效權限（介面合約 §g、§g-2），兩者對稱。

本 task **取代**階段二的：§b `rolesContaining`（改為 `rolesEverContaining`）、§e 的聯集邏輯、§g 的反查邏輯。**沿用**階段二的：`RoleDirectory.resolve`（只剩 `assignRoles` 的 `roleNotFound` 驗證使用）、`assignRoles`／`revokeRoles` 行為、兩個入口共用同一個 `roleDirectory` 實例的注入佈線、消費端 60 秒快取。

---

## 目標與 Non-goals

**目標**：

1. **有效權限＝時間軸重播結果**，取代查詢時聯集。`getPermissions` 的 HTTP 與 gRPC 兩個入口同一版切換（兩者共用 `GetPermissionsApplicationService`，本 task 不改注入佈線）。
2. **`revokePrivilege` 可撤銷來自角色的權限**：沿用既有 command 與 `PrivilegeRevoked` 事件，不新增事件（D1）。前置條件放寬為「權限在直接授權裡，或在有效權限裡」，都不在才回 `permissionNotExist`（`[inferred]`，見介面合約 §g）。
3. **`grantPrivilege` 前置條件與 `revokePrivilege` 對稱**（D5「直接授予能把權限給回來」的推論，`[inferred]` I-11）：`permissionAlreadyExists` 只在權限「既在直接授權、又在有效權限」時回；已在直接授權、但因角色移除而不在有效權限的，可以再授予。判斷同樣由 usecase 以強一致重播完成，aggregate 用帶預設值的參數承接（介面合約 §g-2）。
4. **`getPermissionHolders` 與 `getPermissions` 共用同一套重播**（D6），避免「有權限卻選不到人／選得到人卻沒權限」（該端點有外部消費端：OpportunityContext 後端、mendesky-web 選派人 modal）。
5. **維持階段二的零扇出**：編輯角色（新增權限、移除權限、刪除）**不對任何員工寫入事件**；角色改一次，下一次查詢就是新結果。
6. **重播引擎是純函式**（輸入已排序的事件、輸出權限集合），可脫離 KurrentDB 做單元測試；D3 的每一條規則各有對應測試。
7. **fail-closed 邊界明確**：時間軸讀取階段遇到「無法解析、無法解碼、型別未登記、型別未處理」的事件一律整體失敗（503／gRPC aborted），不略過；每一種事件型別若不是「處理」就必須是「明確忽略」（見介面合約 §a、§c、§e，`[inferred]` I-5、I-12）。
8. gRPC 契約（`proto/PermissionsService.proto`、`Sources/Generated/`）、HTTP schema（兩個 `openapi.yaml`）、JS projection 全部不變；消費端不需改碼（D7、D8）。

**Non-goals（本 task 不做）**：

- **新增專用的排除事件或排除清單**：對個人的移除沿用 `PrivilegeRevoked`（D1）；不記錄「權限來源」這個新狀態（D4）。
- **權限來源明細查詢**（`getEffectivePermissions`：某個權限是直接給的還是來自哪個角色）。後續階段。
- **消費端快取失效機制**：Middleware `CachingPermissionsProvider` 的 60 秒（正結果）／10 秒（空結果）TTL 維持現狀（D7）。
- **歷史資料遷移**：重播直接吃既有事件，不寫回任何資料。行為改變對既有資料的影響見已知限制 #6 與 Human 補做的比對項。
- 改 gRPC proto、HTTP schema、任何 JS projection（D8）；不新增 projection、不需要重新部署 projection。
- **改變 `grantPrivilege` 對「只來自角色的權限」的行為**：權限只在角色裡、不在直接授權時，`grantPrivilege` 照舊可以授予（階段二既有測試 #4 依賴此行為）。本 task 只讓 `permissionAlreadyExists` 改看有效權限（目標 3），不新增 command／事件，也不動 identity guard。
- 重播結果快取或快照。先量測（Human 補做），再決定是否需要。
- 反查對「建檔事件裡的初始角色／初始權限」的候選人發現（見已知限制 #3）。
- 清理 `PermissionsReadModel.permissions`／`roles` 折疊欄位（本 task 後 `getPermissions` 不再使用它們；`department`／`firm` 仍被 `PermissionScopeFilter` 使用）。
- RoleAggregate 內部（Entity／Usecase／event.yaml／openapi.yaml／projection-model.yaml）任何行為變更——本 task 只改 `Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift` 一個檔案。

---

## 實作前提查證

以下三項在撰寫本規格時已對原始碼與本機 KurrentDB（25.1.1.2828，`localhost:2113`）查證；Step 0 要求實作者重跑實測。

### P-a：讀取事件時拿得到全域位置嗎？——**拿得到；但 DDDKit 的 coordinator 把它丟掉了，必須直接用 `KurrentDBClient` 讀**

- client 有位置：`RecordedEvent.position: StreamPosition`（`.build/checkouts/swift-kurrentdb/Sources/KurrentDB/Core/Event/RecordedEvent.swift`，由 `RecordedEvent.init(message:)` 以 `message.commitPosition`／`message.preparePosition` 建立）；`StreamPosition.commit`／`.prepare` 是 public（`.build/checkouts/swift-kurrentdb/Sources/KurrentDB/Core/Stream/StreamPosition.swift`），**只有 `Equatable`、沒有 `Comparable`**——排序鍵要自己定義（介面合約 §a 的 `LogPosition`）。
- 透過 link 讀取時有三個位置，**只能取其中一個**（`.build/checkouts/swift-kurrentdb/Sources/KurrentDB/Core/Event/ReadEvent.swift` 的 `ReadEvent.record`／`ReadEvent.link`／`ReadEvent.commitPosition`；`ReadEvent.init(message:)` 以 `message.event` 建 `record`）：
  - `readEvent.record`：解析後的**原始事件**（`resolveLinks = true` 時），`record.position` 是原始事件在 log 裡的位置——**要用這個**。
  - `readEvent.link`：link 事件本身；其位置是 projection 寫入 link 的時間點，晚於原始事件——**不可用**。
  - `readEvent.commitPosition`（頂層）：實測等於 link 的位置——**不可用**。
  - `resolveLinks` 預設 `false`（`.build/checkouts/swift-kurrentdb/Sources/KurrentDB/Streams/Usecase/Specified/Streams.Read.swift` 的 `Streams.Read.Options.init()`），讀 link stream 必須顯式設 `true`；同一個 `Options` 的 `limit` 預設 `.max`，不需要分頁。
- **實測**（grpcurl 直打 `event_store.client.streams.Streams/Read`，`resolve_links: true`，stream `IAM_GetPermissions-testing<userId>`；proto 定義見 `.build/checkouts/swift-kurrentdb/proto/kurrentdb/v1/streams.proto` 的 `ReadResp.ReadEvent`）：

  | 事件 | `event.event`（原始）commit | `event.link` commit | 頂層 `event.commitPosition` |
  |---|---|---|---|
  | UserAccessProfileCreated（rev 0） | 304843985 | 304846626 | 304846626 |
  | RolesAssigned（rev 1） | 304846123 | 304849527 | 304849527 |
  | PrivilegeGranted（rev 2） | 304848982 | 304852883 | 304852883 |
  | RolesRevoked（rev 3） | 304854287 | 304855399 | 304855399 |

  原始事件的位置一律早於其 link 的位置，證實取 `record` 才是「事件真正發生的順序」。另（audit-spec 2026-09-30 重跑）每筆 `event.event.streamIdentifier` base64 解碼為 `IAMEmployeeAccess-<employeeAccessId>`（員工原始 stream，**不是** `$ce-IAMEmployeeAccess` 裡的 link），`event.link` 的 eventType 為 `$>`、streamIdentifier 解碼為 `IAM_GetPermissions-<userId>`。單事件 append 時 `commit == prepare`；多事件同一次 append 時以 `(commit, prepare)` 字典序排（即 `$all` 自己的排序）。
- **DDDKit 丟掉位置**：`KurrentStorageCoordinator.fetchEvents(byId:)`（`.build/checkouts/swift-ddd-kit/Sources/KurrentSupport/Adapter/KurrentStorageCoordinator.swift`）讀取時有 `resolveLinks = true` 並取 `response.event.record`，但只保留解碼後的 `DomainEvent`，再以 `occurred`（寫入端本機時鐘）排序；`DomainEvent` 協定（`.build/checkouts/swift-ddd-kit/Sources/DDDCore/DomainEvent.swift`）沒有位置欄位。所以時間軸讀取不能走 `presenter.execute`／`fetchEvents`，要像 `RoleAggregateDirectory` 一樣持有 `KurrentDBClient` 直接 `streams(specified:).read`，解碼交給既有 `EventTypeMapper.mapping(eventData:)`（`.build/checkouts/swift-ddd-kit/Sources/KurrentSupport/Adapter/EventTypeMapper.swift`）。
- **讀取端的兩個靜默略過，時間軸讀取都不可繼承**（`[inferred]` I-5、I-12；權限系統 fail-closed）：
  1. `fetchEvents` 對「解碼拋錯」只記 warning 就略過，對「mapper 回 `nil`」也直接略過。生成的 `EmployeeAccessAggregateEventMapper`／`RoleAggregateEventMapper`（`.build/plugins/outputs/iamcontext/<Target>/destination/ModelGeneratorPlugin/generated/generated-event-mapper.swift`）在 eventType 不在對照表、或內容不是 JSON 時回 `nil`。時間軸讀取對這兩種情況都**整體失敗**（介面合約 §a 的 `PermissionTimelineError`）。
  2. `Streams.ReadResponse.event`（`.build/checkouts/swift-kurrentdb/Sources/KurrentDB/Streams/Streams.ReadResponse.swift`）在 `.unserviceable(link: nil)` 時拋 `KurrentError.resourceNotFound(reason: "read event not found.")`，與「stream 不存在」（迭代時由 `streamNotFound` 訊息拋出的 `resourceNotFound`）是**同一個 error case**。若用 `try response.event.record` 並以 `catch KurrentError.resourceNotFound` 表示「stream 不存在」，「單一事件無法解析」會被誤判成「stream 不存在」而靜默丟掉事件（角色歷史缺一筆 `RolePermissionsRemoved` 就會讓已被移除的權限復活）。因此讀取迴圈**不用 `response.event`**，改為 `guard case let .event(readEvent) = response`，其他 case（`.unserviceable`）一律拋 `PermissionTimelineError.unresolvableEvent`。
- **風險（`[inferred]`）**：「link 的 `record` 帶原始位置」是伺服器行為，client 原始碼裡看不出來，只由上表實測與 KurrentDB 25.1.1 確認。以整合測試 #24 釘住（同一事件從 link stream 與從原始 stream 讀到的 `record.position` 必須相等，且都早於 link 位置），伺服器升級若改行為會在此紅燈。

### P-b：`repository.delete` 對角色是 soft delete 還是 tombstone？——**寫入 `RoleDeleted` 事件（append-only）；刪除後原始事件全部仍讀得到，已刪除角色的歷史可完整重播**

- `DeleteRoleUsecase`（`Sources/RoleAggregate/Usecase/Port/In/DeleteRole/DeleteRoleUsecase.swift`）呼叫 `repository.delete(byId:external:)` → `EventSourcingRepository.delete(byId:external:)`：`find` → `markDelete()` → `save`（`.build/checkouts/swift-ddd-kit/Sources/EventSourcing/EventSourcingRepository.swift`）；`AggregateRoot.markDelete()` 建立 `DeletedEventType`（此處為 `RoleDeleted`）並 `apply`（`.build/checkouts/swift-ddd-kit/Sources/DDDCore/Entity/AggregateRoot.swift`）；`save` 是 `KurrentStorageCoordinator.append(events:byId:version:external:)`。**沒有** `tombstone`、沒有 stream 層級的刪除。
- 唯一會讓 stream 從讀取端消失的路徑是 `repository.purge(byId:)`（`EventSourcingRepository.purge(byId:)` → `KurrentStorageCoordinator.purge(byId:)` → `streams(specified:).delete()`，即 KurrentDB 的 soft delete，`.build/checkouts/swift-kurrentdb/Sources/KurrentDB/Streams/Usecase/Specified/Streams.Delete.swift`）。`/usr/bin/grep -rniE "purge|tombstone" Sources` 無任何呼叫者（驗收標準的 P-b 守門項每次都會重查）。
- **實測**：本機已刪除角色 `IAMRole-<roleId>` 讀到 5 筆事件（RoleCreated rev 0、RolePermissionsAdded rev 1、RolePermissionsRemoved rev 2、RoleRenamed rev 3、**RoleDeleted rev 4**，commit 304536351 → 304691783），stream metadata 為 `{}`（無 truncate／tombstone）。
- **含意**：`find(byId:)` 預設隱藏已刪除 aggregate（`EventSourcingRepository.find(byId:hiddingDeleted:)`），所以階段二 `resolve` 對已刪除角色回不出內容；時間軸重播不走 `find`，直接讀原始事件，因此 D3 的「刪除角色」規則可從歷史重播，也能處理「員工指派角色之後才刪除」與「刪除之後才查詢」。若日後有人引入 `purge`／tombstone，`unservicableEventLink`（`.build/checkouts/swift-kurrentdb/Sources/KurrentDB/Streams/Streams.ReadResponse.swift` 的 `ReadResponse.event`）與 `resourceNotFound`（`.build/checkouts/swift-kurrentdb/Sources/KurrentDB/Core/Error/KurrentError.swift`）會讓重播失敗或缺歷史——見失敗路徑。
- **角色事件 payload 的兩個前提**（引擎正確性依賴，非本 task 新增，但要釘住）：
  1. `RoleCreated` 不帶權限（`Sources/RoleAggregate/event.yaml`：只有 `name`、`description`）；角色的權限只能經 `RolePermissionsAdded` 進入。目前唯一建角色路徑 `CreateRoleUsecase` 用 `Role(name:description:)`，該 init 以空權限建立。
  2. `RolePermissionsAdded`／`RolePermissionsRemoved` 的 `permissions` 是**淨變化**（`Role.addPermissions` 先 `subtracting` 現有權限、`Role.removePermissions` 先 `intersection` 現有權限，再產生事件；淨變化為空就拋 `permissionsUnchanged`，不寫事件）。若日後改成攜帶「請求全集」，`rolePermissionsRemoved` 會誤把員工直接授權、但不在該角色的權限一起移除。

### P-c：合併重播放哪裡，才不讓 EmployeeAccessAggregate 依賴 RoleAggregate？——**擴充既有 `RoleDirectory` port；重播引擎與員工側讀取放 EmployeeAccessAggregate，角色事件解碼留在 RoleAggregate adapter**

- 依賴方向已固定為 RoleAggregate → EmployeeAccessAggregate（`Package.swift` 的 `RoleAggregate` target：`dependencies` 裡 `.target(name: "EmployeeAccessAggregate")` 上方的註解明示單向、不得反向）；`RoleCreated`／`RolePermissionsAdded` 等事件型別由 RoleAggregate 的 codegen 產生（`Sources/RoleAggregate/event.yaml`），EmployeeAccessAggregate 看不到它們，因此角色事件的**解碼**只能在 RoleAggregate 端做，跨過 port 時要轉成中性的值型別（介面合約 §a 的 `TimelineEntry`）。
- **選擇（方案 1）**：`RoleDirectory` 新增 `history(ofRoles:)`（回傳角色事件的中性表示）與 `rolesEverContaining(permission:)`（取代 `rolesContaining`）。重播引擎（純函式）、員工側 stream 讀取、候選人發現放 EmployeeAccessAggregate。
- 取捨：

  | 方案 | 優點 | 缺點 |
  |---|---|---|
  | **1. 擴充 `RoleDirectory`（採用）** | 注入點已佈好（`ApiHandler` 與 `PermissionsService` 共用 `IAMContextServer.swift` 裡建立的同一個 `RoleAggregateDirectory` 實例），本 task 不動任何佈線；RoleAggregate 的事件型別不外洩；依賴方向不變 | port 從 2 個方法長成 3 個（`resolve` 仍給 `assignRoles` 用）；`FakeRoleDirectory`／`ThrowingRoleDirectory` 兩個測試替身要跟著加方法 |
  | 2. 新增獨立 port（如 `RoleHistoryReader`） | 職責單一 | 第二個建構參數要穿過 `ApiHandler`、`PermissionsService`、4 個 Application Service（getPermissions、getPermissionHolders、revokePrivilege、grantPrivilege）、`IAMContextServer`，階段二剛整理過的呼叫點與測試又要全部再改一輪，沒有對應收益 |
  | 3. 重播放 IAMContextServer（組裝根） | port 不變 | HTTP `ApiHandler` 在 EmployeeAccessAggregate，仍需注入一個 resolver；邏輯放 executable target，測試只能 `@testable import IAMContextServer`，也混淆分層 |
  | 4. 抽共用 target 放事件型別 | 兩個 aggregate 都能解碼 | 要搬 codegen 產物，遠超本 task 範圍 |

### 規格層驗證紀錄（audit-spec，2026-09-30）

- 在專案的 APFS 副本（不動原 repo）依本規格實作 §a–§h、§j 的程式碼與所有呼叫點替換：`swift build --build-tests` 綠、新程式碼無警告；`Package.swift` 不需修改（確認「不需要修改」清單）。
- 在副本對本機 KurrentDB 25.1.1.2828 跑全套 `swift test`：既有測試全綠（含反轉後的 #4）；新寫的整合測試 #13、#21、#24、#25、#26、#27 與 4 條單元測試（`mentionedRoleIds`、撤銷沒持有的角色、重複員工事件、D4 失去後再直接授予）實測通過——副本沒有實作 U1–U15、#14–#20、#22、#23，這些只由本規格描述。
- 實測揭露的實作細節已寫入規格：#27 的 gRPC 斷言不能用會 `Issue.record` 的 helper；`GrantPrivilegeService(repository:)` 等呼叫點的數量與機械替換寫法；`scripts/projection.sh` 是破壞性重建，不能當「已部署」檢查。

---

## 介面合約（Interface Contract）

### a. 時間軸型別與重播引擎（新增，`Sources/EmployeeAccessAggregate/Entity/PermissionTimeline/PermissionTimeline.swift`）

```swift
import Foundation

/// KurrentDB 全域日誌位置（`$all` 的排序鍵）。P-a：client 的 `StreamPosition` 只有 Equatable，排序鍵自己定義。
/// 全序：先比 commit、再比 prepare（字典序，與 `$all` 自己的排序一致）。
package struct LogPosition: Sendable, Hashable, Comparable {
    package let commit: UInt64
    package let prepare: UInt64

    package init(commit: UInt64, prepare: UInt64) {
        self.commit = commit
        self.prepare = prepare
    }

    package static func < (lhs: LogPosition, rhs: LogPosition) -> Bool {
        (lhs.commit, lhs.prepare) < (rhs.commit, rhs.prepare)
    }
}

/// 時間軸上的一個事件的中性表示（不含 codegen 事件型別，可跨 target 傳遞）。
/// 員工事件（前 5 個）與角色事件（後 4 個）併在同一個 enum，讓引擎只面對一種輸入。
/// 不影響權限的事件型別——員工側 `UserPromoted`／`DepartmentTransferred`／`EmployeeAccessDeleted`、
/// 角色側 `RoleRenamed`／`RoleDescriptionUpdated`——由讀取端在 `switch` 裡**逐一列名忽略**，不進時間軸；
/// 型別若既不在「處理」也不在「明確忽略」清單（例如日後新增的事件），讀取端拋 `PermissionTimelineError.unhandledEvent`。
package enum TimelineEvent: Sendable, Equatable {
    // EmployeeAccess stream
    case profileCreated(permissions: Set<String>, roles: Set<String>)
    case privilegeGranted(permissions: Set<String>)
    case privilegeRevoked(permissions: Set<String>)
    case rolesAssigned(roleIds: Set<String>)
    case rolesRevoked(roleIds: Set<String>)
    // Role stream
    case roleCreated(roleId: String)
    case rolePermissionsAdded(roleId: String, permissions: Set<String>)
    case rolePermissionsRemoved(roleId: String, permissions: Set<String>)
    case roleDeleted(roleId: String)
}

package struct TimelineEntry: Sendable, Equatable {
    /// 原始事件的全域位置（P-a：link 事件取 `record` 的位置，不是 link 自己的位置）。
    package let position: LogPosition
    package let event: TimelineEvent

    package init(position: LogPosition, event: TimelineEvent) {
        self.position = position
        self.event = event
    }
}

/// 時間軸讀取的 fail-closed 錯誤（`[inferred]` I-5、I-12）：權限系統寧可 503／gRPC aborted，也不猜測。
/// 讀取端（`RoleAggregateDirectory.history`、`PermissionTimelineService.readEmployeeEntries`）共用。
package enum PermissionTimelineError: Error, Sendable, Equatable {
    /// 讀取回應不是可用事件（`Streams.ReadResponse.unserviceable`：link 指向的原始事件已不存在或無法解析）。
    case unresolvableEvent(stream: String)
    /// `EventTypeMapper.mapping` 回 `nil`：eventType 不在對照表，或內容不是 JSON。
    case unmappedEvent(stream: String, eventType: String)
    /// mapper 解得出、但既不是時間軸要處理、也不在「明確忽略」清單的事件型別。
    case unhandledEvent(stream: String, eventType: String)
}

extension TimelineEvent {
    /// role 事件所屬的 roleId；員工事件回 nil。
    package var roleId: String? {
        switch self {
        case let .roleCreated(roleId),
             let .rolePermissionsAdded(roleId, _),
             let .rolePermissionsRemoved(roleId, _),
             let .roleDeleted(roleId):
            return roleId
        case .profileCreated, .privilegeGranted, .privilegeRevoked, .rolesAssigned, .rolesRevoked:
            return nil
        }
    }
}

package enum PermissionTimeline {
    /// 員工事件裡出現過的所有 roleId（建檔初始角色、曾被指派或撤銷的角色）——
    /// 這些角色的歷史都要讀（從角色建立開始，D2）。
    package static func mentionedRoleIds(in entries: [TimelineEntry]) -> Set<String> {
        var roleIds: Set<String> = []
        for entry in entries {
            switch entry.event {
            case let .profileCreated(_, roles):
                roleIds.formUnion(roles)
            case let .rolesAssigned(ids), let .rolesRevoked(ids):
                roleIds.formUnion(ids)
            case .privilegeGranted, .privilegeRevoked,
                 .roleCreated, .rolePermissionsAdded, .rolePermissionsRemoved, .roleDeleted:
                break   // 不列 default：日後新增 case 時編譯器會強迫這裡表態
            }
        }
        return roleIds
    }

    /// 重播：`entries` 可為任意順序（員工事件與角色事件混在一起），內部依 `(position, 輸入順序)` 排序。
    /// 規則見 §d。純函式、無 I/O。
    package static func replay(_ entries: [TimelineEntry]) -> Set<String> {
        var effective: Set<String> = []           // S：有效權限集合
        var held: Set<String> = []                // H：員工目前持有的 roleId
        var content: [String: Set<String>] = [:]  // C[r]：角色 r 重播到目前時間點的內容

        func contents(of roleIds: Set<String>) -> Set<String> {
            roleIds.reduce(into: Set<String>()) { $0.formUnion(content[$1] ?? []) }
        }

        let ordered = entries.enumerated()
            .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
            .map(\.element)

        for entry in ordered {
            switch entry.event {
            case let .profileCreated(permissions, roles):
                held.formUnion(roles)
                effective.formUnion(permissions)
                effective.formUnion(contents(of: roles))
            case let .privilegeGranted(permissions):
                effective.formUnion(permissions)
            case let .privilegeRevoked(permissions):
                effective.subtract(permissions)
            case let .rolesAssigned(roleIds):
                held.formUnion(roleIds)
                effective.formUnion(contents(of: roleIds))
            case let .rolesRevoked(roleIds):
                let removing = held.intersection(roleIds)
                held.subtract(removing)
                effective.subtract(contents(of: removing).subtracting(contents(of: held)))
            case let .roleCreated(roleId):
                content[roleId] = content[roleId] ?? []
            case let .rolePermissionsAdded(roleId, permissions):
                content[roleId, default: []].formUnion(permissions)
                if held.contains(roleId) { effective.formUnion(permissions) }
            case let .rolePermissionsRemoved(roleId, permissions):
                content[roleId, default: []].subtract(permissions)
                if held.contains(roleId) {
                    effective.subtract(permissions.subtracting(contents(of: held.subtracting([roleId]))))
                }
            case let .roleDeleted(roleId):
                let removed = content[roleId] ?? []
                content[roleId] = []
                if held.contains(roleId) {
                    effective.subtract(removed.subtracting(contents(of: held.subtracting([roleId]))))
                }
            }
        }
        return effective
    }
}
```

- 上列引擎已在規格撰寫時以獨立 `swiftc` 編譯並跑過 30 個檢查點（D3 每條規則、D4 三條路徑、D5 四條路徑、兩角色重疊三條路徑、同時撤銷兩個重疊角色、排序與同位置 fallback），全數符合本檔 §d 與驗收標準的預期。audit-spec（2026-09-30）另以 `/usr/bin/swiftc -package-name pkg` 重新編譯本區塊，並加跑 §g-2 情境（直接授予且角色也有 → 角色移除後失去 → 再直接授予後擁有）、重複 link、同 commit 不同 prepare 等檢查點，全數符合。實作時仍以 Step 1 的單元測試為準。
- **排序鍵**：`(position, 輸入順序)`。真實事件位置唯一：單次 append 的多個事件共用 commit、prepare 遞增，`(commit, prepare)` 字典序即寫入順序；**輸入順序只在位置相同時當 tie-break**——位置相同只會出現在兩種情況：測試替身（`FakeRoleDirectory` 的合成歷史，見 §j）、同一原始事件經重複 link 出現多次（見下）。呼叫端的輸入順序約定：員工事件在前、角色事件在後（`employeeEntries + roleEntries`）。
- **link 重複時冪等**：若 `IAM_GetPermissions-<userId>` 出現重複 link（`scripts/projection.sh` 重建 projection 時 `deleteEmittedStreams=true` 會先清掉舊 link，正常不會重複；手動建立同名 projection 且沒清 emitted streams 才會），同一原始事件的位置相同、排序後相鄰（穩定排序，輸入順序當 tie-break），每條規則又都是集合運算，重複套用不改變結果——單元測試 U18 釘住。
- **引擎依賴的兩個 payload 前提**（P-b 末項）：`RoleCreated` 不帶權限、`RolePermissionsAdded`／`RolePermissionsRemoved` 攜帶淨變化。前提失效時 D3 的「角色 R 移除權限 P」會多移除員工直接授權的權限。

### b. `protocol RoleDirectory`（修改，`Sources/EmployeeAccessAggregate/Usecase/Port/Out/RoleDirectory.swift`）

```swift
package protocol RoleDirectory: Sendable {
    /// （不變）解析一批 roleId 各自「目前」的權限集合；查不到或已刪除的 roleId 不出現在字典的 key 中。
    /// 本 task 後只剩 `assignRoles` 的存在性驗證使用；有效權限改走 `history(ofRoles:)`。
    func resolve(roleIds: Set<String>) async throws -> [String: Set<String>]

    /// （新增）這些角色的權限相關歷史事件，每個角色從 `RoleCreated` 開始到目前為止（含已刪除角色的
    /// `RoleDeleted`；P-b：刪除是 append 事件，原始事件仍可讀）。
    /// - 只回 `roleCreated`／`rolePermissionsAdded`／`rolePermissionsRemoved`／`roleDeleted` 四種
    ///   role 事件（`RoleRenamed`／`RoleDescriptionUpdated` 不影響權限，**明確列名忽略**）。
    /// - `position` 是原始事件的全域位置。
    /// - 沒有對應 stream 的 roleId（歷史舊字串、從未建立）不產生任何 entry，也不報錯（貢獻零權限）。
    /// - fail-closed：事件無法解析、無法解碼、型別未登記或未處理時拋 `PermissionTimelineError`（或 mapper 的解碼錯誤），
    ///   不略過、不回部分歷史。
    /// - 回傳順序不保證；呼叫端併入時間軸後由 `PermissionTimeline.replay` 依位置排序。
    /// - 強一致：直接讀角色原始 stream，不經 projection。
    func history(ofRoles roleIds: Set<String>) async throws -> [TimelineEntry]

    /// （新增，取代 `rolesContaining(permission:)`）任何時候含過 `permission` 的角色 roleId，
    /// **包含目前已刪除的角色，也包含後來被移除該權限的角色**（D6 的候選人來源）。
    /// 走 `IAM_GetRoles-all` link stream 的 `RolePermissionsAdded` 事件（不折疊；最終一致）。
    /// projection 未部署或尚無角色時回空集合，不報錯；KurrentDB 不可用等其他錯誤向上拋。
    func rolesEverContaining(permission: String) async throws -> Set<String>
}
```

Step 5 之前 `rolesContaining(permission:)` 暫時保留（讓每一步 `swift build` 都綠）；Step 5 從 port、實作與兩個測試替身一併刪除。

### c. `RoleAggregateDirectory`（修改，`Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift`）

新增的 import 必須用**具名 import**（`EmployeeAccessAggregate` 與 `RoleAggregate` 各自有 `ApiHandler` 等同名型別，全模組 import 會在使用處產生歧義；該檔現有的 `import protocol EmployeeAccessAggregate.RoleDirectory` 即是同一原因）：

```swift
import DDDKit
import Foundation
import KurrentDB
import IAMContextShared
import protocol EmployeeAccessAggregate.RoleDirectory
import struct EmployeeAccessAggregate.LogPosition
import struct EmployeeAccessAggregate.TimelineEntry
import enum EmployeeAccessAggregate.PermissionTimelineError
```

`TimelineEvent` 不需要另外具名 import：程式碼只用 `.roleCreated(...)` 這類隱含成員語法，型別由 `TimelineEntry.init(position:event:)` 的參數推斷（audit-spec 2026-09-30 在完整實作的副本中編譯通過，未出現警告）。

```swift
package func history(ofRoles roleIds: Set<String>) async throws -> [TimelineEntry] {
    let mapper = RoleAggregateEventMapper()
    var entries: [TimelineEntry] = []
    for roleId in roleIds.sorted() {
        let streamName = Role.getStreamName(id: roleId)   // IAMRole-<roleId>
        do {
            // 直接讀角色原始 stream（P-b：已刪除角色的事件仍在），不用 repository.find（會隱藏已刪除）。
            let responses = try await kdbClient.streams(specified: streamName).read {
                $0.direction = .forward
                $0.revision = .start
            }
            for try await response in responses {
                // 不用 `response.event`（P-a：它把「事件無法解析」也丟成 resourceNotFound，
                // 會被下面「stream 不存在」的 catch 誤吞）；非 `.event` 一律 fail-closed。
                guard case let .event(readEvent) = response else {
                    throw PermissionTimelineError.unresolvableEvent(stream: streamName)
                }
                let record = readEvent.record
                guard let event = try mapper.mapping(eventData: record) else {
                    throw PermissionTimelineError.unmappedEvent(stream: streamName, eventType: record.eventType)
                }
                let position = LogPosition(commit: record.position.commit, prepare: record.position.prepare)
                switch event {
                case is RoleCreated:
                    entries.append(.init(position: position, event: .roleCreated(roleId: roleId)))
                case let added as RolePermissionsAdded:
                    entries.append(.init(position: position, event: .rolePermissionsAdded(roleId: roleId, permissions: added.permissions)))
                case let removed as RolePermissionsRemoved:
                    entries.append(.init(position: position, event: .rolePermissionsRemoved(roleId: roleId, permissions: removed.permissions)))
                case is RoleDeleted:
                    entries.append(.init(position: position, event: .roleDeleted(roleId: roleId)))
                case is RoleRenamed, is RoleDescriptionUpdated:
                    continue   // 明確忽略：不影響權限
                default:
                    throw PermissionTimelineError.unhandledEvent(stream: streamName, eventType: record.eventType)
                }
            }
        } catch KurrentError.resourceNotFound(_) {
            // 只剩 read 開頭的 streamNotFound（沒有這個 stream：歷史舊字串、從未建立）→ 零貢獻。
            // 事件層級的失敗已在上面改拋 PermissionTimelineError，不會走到這裡。
            continue
        }
    }
    return entries
}

package func rolesEverContaining(permission: String) async throws -> Set<String> {
    let presenter = GetRolesPresenter(coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper()))
    // `IAM_GetRoles-all` 連結了全部角色事件（含已刪除角色）；不折疊成目前狀態，直接掃 RolePermissionsAdded。
    // coordinator.fetchEvents 對 stream 不存在回 nil（projection 未部署／尚無角色）→ 空集合；其他錯誤向上拋。
    guard let fetched = try await presenter.coordinator.fetchEvents(byId: GetRolesInput().id) else { return [] }
    var roleIds: Set<String> = []
    for case let event as RolePermissionsAdded in fetched.events where event.permissions.contains(permission) {
        roleIds.insert(event.roleId)
    }
    return roleIds
}
```

- `Role.getStreamName(id:)` 產生 `IAMRole-<roleId>`（`Sources/RoleAggregate/Entity/Role.swift` 的 `Role.category` 為 `"IAM\(Self.self)"`，再由 `EventStreamNaming.getStreamName(id:)` 組成；本機實測 stream 名稱吻合）。
- **一律取 `record.position`**，不使用 link 事件與頂層 `commitPosition`（P-a）。此處讀的是原始 stream，`record` 本來就是原始事件；程式碼仍統一寫法，讓兩個讀取點（此處與 §e）行為一致。
- **fail-closed 三層**（`[inferred]` I-5、I-12；理由：略過一筆撤銷事件會讓被撤銷的權限復活）：(1) 回應不是 `.event`（`.unserviceable`）→ `unresolvableEvent`；(2) `mapping` 拋錯（解碼失敗）→ 原樣向上拋；`mapping` 回 `nil`（型別未登記／非 JSON）→ `unmappedEvent`；(3) 解得出、但不在「處理」也不在「明確忽略」清單 → `unhandledEvent`。三者都不回部分歷史。只有讀取開頭的 `streamNotFound`（stream 不存在）視為零貢獻。
- **`rolesEverContaining` 不在 fail-closed 範圍**：它經 `KurrentStorageCoordinator.fetchEvents`，該方法對解碼失敗只記 warning 並略過。這裡的結果只是候選人的超集合來源（誰要被重播），漏一個角色的後果是反查少列人，不會讓 `getPermissions` 給出錯誤權限；有效權限的正確性完全由 `history` 與員工側讀取決定。
- `resolve` 不動；`rolesContaining` 於 Step 5 刪除。

### d. 重播規則（D3 每條的精確集合運算）

符號：`S`＝有效權限集合；`H`＝員工目前持有的 roleId 集合；`C[r]`＝角色 `r` 重播到目前時間點的內容（未見過的角色視為 `∅`）；`Others(X) = ⋃{ C[q] | q ∈ H \ X }`＝該時間點仍持有的其他角色（排除集合 `X`）用**當時**內容的聯集。事件依 §a 的排序逐一套用，初始 `S = H = ∅`、`C` 為空字典。

| 事件（D3 規則） | 對 `H`／`C` | 對 `S` |
|---|---|---|
| `profileCreated(P₀, R₀)`（建立 profile：重設起點為初始權限與初始角色；見實作回填 #5） | `H ← R₀` | `S ← P₀ ∪ ⋃{ C[r] \| r ∈ R₀ }` |
| `privilegeGranted(P)`（直接授予） | — | `S ← S ∪ P` |
| `privilegeRevoked(P)`（撤銷權限，**不論來源**） | — | `S ← S \ P` |
| `rolesAssigned(Rs)`（指派角色） | `H ← H ∪ Rs` | `S ← S ∪ ⋃{ C[r] \| r ∈ Rs }` |
| `rolesRevoked(Rs)`（撤銷角色；`Rs` 內只有原本在 `H` 的才算） | `Rm = H ∩ Rs`；`H ← H \ Rm` | `S ← S \ ( ⋃{ C[r] \| r ∈ Rm } \ Others(∅) )`（此時 `H` 已扣掉 `Rm`，所以 `Others(∅)` 就是撤銷後仍持有的角色內容） |
| `roleCreated(r)` | `C[r] ← C[r] ?? ∅` | — |
| `rolePermissionsAdded(r, P)`（角色新增權限） | `C[r] ← C[r] ∪ P` | 若 `r ∈ H`：`S ← S ∪ P`；否則不動 |
| `rolePermissionsRemoved(r, P)`（角色移除權限） | `C[r] ← C[r] \ P` | 若 `r ∈ H`：`S ← S \ ( P \ Others({r}) )`；否則不動 |
| `roleDeleted(r)`（刪除角色） | `Cold = C[r]`；`C[r] ← ∅`（`H` 不變，`[inferred]` I-7） | 若 `r ∈ H`：`S ← S \ ( Cold \ Others({r}) )`（同撤銷角色）；否則不動 |

規則含意（每條都有對應測試，見驗收標準）：

- **D4 角色與角色重疊保留**：撤銷角色／角色移除權限／刪除角色三條路徑的差集都減去 `Others`，另一個角色仍供應的權限不會消失。
- **D4 直接授權不保留**：`Others` 只看角色內容，不看直接授權；直接授予的 P 若也在被撤銷／被移除／被刪除的角色裡，就跟著從 `S` 消失。時間軸不記錄權限來源，這是刻意取捨（D4）。
- **D5 最新事件說了算**：`privilegeRevoked(P)` 之後，`privilegeGranted(P)`、`rolesAssigned`（含 P 的角色）、`rolePermissionsAdded`（持有中的角色加入 P）都會把 P 加回 `S`。
- **角色內容是「重播到該時間點」的內容**：`rolesAssigned` 用指派當下的 `C[r]`；指派之後角色的改動由後續的角色事件處理。所以「先有人收回直接授權、之後角色才加入同一權限」結果是員工擁有該權限（D5）。
- **未持有的角色**發生事件只更新 `C`，不動 `S`；日後被指派時用當時內容。
- 未知 roleId（舊字串）永遠是 `C[r] = ∅`，貢獻零權限。

**事件型別處置總表**（兩個 `event.yaml` 的全部型別；讀取端的 `switch` 必須逐一列名，沒列到的型別 → `PermissionTimelineError.unhandledEvent`）：

| 來源 stream | 事件型別 | 處置 |
|---|---|---|
| 員工（`IAM_GetPermissions-<userId>` link stream 與 `IAMEmployeeAccess-<id>` 原始 stream） | `UserAccessProfileCreated` | 處理 → `profileCreated`（初始權限與初始角色） |
| 同上 | `PrivilegeGranted`／`PrivilegeRevoked`／`RolesAssigned`／`RolesRevoked` | 處理 → 同名 `TimelineEvent` |
| 同上 | `UserPromoted`／`DepartmentTransferred` | 明確忽略：不影響權限（department／firm 由 `PermissionScopeFilter` 讀 `GetPermissionsPresenter` 折疊，不在時間軸） |
| 員工原始 stream | `EmployeeAccessDeleted` | 明確忽略：`IAM_GetPermissionsProjection.js` 不轉送它（已知限制 #8）；原始 stream 路徑（revoke／grant 前置檢查）前面的 `repository.find` 已把已刪除的 aggregate 擋成 `aggregateNotFound`，走不到重播 |
| 角色（`IAMRole-<roleId>` 原始 stream） | `RoleCreated` | 處理 → `roleCreated`（`C[r] ← ∅`；此事件不帶權限，P-b 前提 1） |
| 同上 | `RolePermissionsAdded`／`RolePermissionsRemoved`／`RoleDeleted` | 處理 → 同名 `TimelineEvent` |
| 同上 | `RoleRenamed`／`RoleDescriptionUpdated` | 明確忽略：不影響權限（整合測試 #26 釘住：改名、改描述前後有效權限不變，且不會讓已被個別撤銷的權限復活） |
| 任一 stream | 上表未列名的型別（含日後新增的事件） | 拋 `unhandledEvent`（mapper 回 `nil` 則拋 `unmappedEvent`）——新增事件型別的人必須回來表態「處理」或「忽略」 |

範例（位置由小到大）：角色 A、B 都含 `p`；員工持有 A、B 且直接授予過 `p`：`S = {p, …}` → 撤銷 A：`p ∈ C[B]`，`S` 仍含 `p` → 對個人撤銷 `p`：`S` 不含 `p` → 撤銷 B：`p` 已不在 `S`，維持不含 → 再指派 A：`S ∪= C[A]`，`p` 回來（D5）。

### e. `EffectivePermissionsReader` 與 `PermissionTimelineService`（新增）

**`Sources/EmployeeAccessAggregate/Usecase/Port/Out/EffectivePermissionsReader.swift`**（供 `RevokePrivilegeUsecase`、`GrantPrivilegeUsecase` 使用的出埠，比照 `RoleDirectory` 的擺法）：

```swift
package protocol EffectivePermissionsReader: Sendable {
    /// 以員工**原始 stream**（`IAMEmployeeAccess-<employeeAccessId>`，強一致、不經 projection）重播出的有效權限。
    /// stream 不存在回空集合。
    func effectivePermissions(employeeAccessId: String) async throws -> Set<String>
}
```

**`Sources/EmployeeAccessAggregate/Adapter/PermissionTimeline/PermissionTimelineService.swift`**：

```swift
import DDDKit
import Foundation
import KurrentDB
import IAMContextShared

package struct PermissionTimelineService: EffectivePermissionsReader {
    private let kdbClient: KurrentDBClient
    private let roleDirectory: RoleDirectory

    package init(kdbClient: KurrentDBClient, roleDirectory: RoleDirectory) {
        self.kdbClient = kdbClient
        self.roleDirectory = roleDirectory
    }

    // MARK: 查詢路徑（員工側最終一致）——員工事件取自 link stream `IAM_GetPermissions-<userId>`

    /// 批次重播。stream 不存在（未建檔、projection 未部署）的 userId 不出現在結果字典。
    /// 所有 userId 共用**一次**角色歷史讀取（每個 roleId 一次 stream 讀取）。
    package func effectivePermissions(userIds: [String]) async throws -> [String: Set<String>] {
        var employeeEntries: [String: [TimelineEntry]] = [:]
        for userId in userIds {
            let streamName = GetPermissionsPresenter.getStreamName(id: userId)   // IAM_GetPermissions-<userId>
            if let entries = try await readEmployeeEntries(streamName: streamName, resolveLinks: true) {
                employeeEntries[userId] = entries
            }
        }
        return try await replayAll(employeeEntries)
    }

    /// `getPermissions` 用。nil＝該員工不存在（沿用既有 notFound 語意）。
    package func effectivePermissions(userId: String) async throws -> Set<String>? {
        try await effectivePermissions(userIds: [userId])[userId]
    }

    // MARK: 寫入前置檢查路徑（強一致）——員工事件取自原始 stream `IAMEmployeeAccess-<employeeAccessId>`

    package func effectivePermissions(employeeAccessId: String) async throws -> Set<String> {
        let streamName = EmployeeAccess.getStreamName(id: employeeAccessId)      // IAMEmployeeAccess-<id>
        guard let entries = try await readEmployeeEntries(streamName: streamName, resolveLinks: false) else { return [] }
        return try await replayAll([employeeAccessId: entries])[employeeAccessId] ?? []
    }

    // MARK: D6 候選人（超集合；每人重播才是真相）

    /// 曾被直接授予該權限的人 ∪ 曾持有「任何時候含過該權限的角色」的人。
    /// 順序：曾被直接授予者依首次授予順序在前；只經由角色者排序後接在後面；已去重。
    package func candidateUserIds(permission: String) async throws -> [String] {
        // 1. 曾被直接授予：IAM_GetPermissionHolders-<permission> 的 PrivilegeGranted 事件（不看 PrivilegeRevoked）。
        let holdersPresenter = GetPermissionHoldersPresenter(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
        var granted: [String] = []
        if let fetched = try await holdersPresenter.coordinator.fetchEvents(byId: permission) {
            for case let event as PrivilegeGranted in fetched.events where !granted.contains(event.userId) {
                granted.append(event.userId)
            }
        }

        // 2. 任何時候含過該權限的角色（含已刪除、含後來被移除者）→ 這些角色的曾持有者：
        //    IAM_GetRoleHolders-<roleId> 的 RolesAssigned 事件（不看 RolesRevoked）。
        let roleIds = try await roleDirectory.rolesEverContaining(permission: permission)
        var viaRoles: Set<String> = []
        if !roleIds.isEmpty {
            let roleHoldersPresenter = GetRoleHoldersPresenter(
                coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
            )
            for roleId in roleIds.sorted() {
                guard let fetched = try await roleHoldersPresenter.coordinator.fetchEvents(byId: roleId) else { continue }
                for case let event as RolesAssigned in fetched.events where event.roles.contains(roleId) {
                    viaRoles.insert(event.userId)
                }
            }
        }
        return granted + viaRoles.subtracting(granted).sorted()
    }

    // MARK: 內部

    private func replayAll(_ employeeEntries: [String: [TimelineEntry]]) async throws -> [String: Set<String>] {
        let mentioned = employeeEntries.mapValues { PermissionTimeline.mentionedRoleIds(in: $0) }
        let allRoleIds = mentioned.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var roleEntries: [TimelineEntry] = []
        if !allRoleIds.isEmpty {
            roleEntries = try await roleDirectory.history(ofRoles: allRoleIds)
        }
        var result: [String: Set<String>] = [:]
        for (key, entries) in employeeEntries {
            let mine = mentioned[key] ?? []
            let relevant = roleEntries.filter { entry in entry.event.roleId.map { mine.contains($0) } ?? false }
            result[key] = PermissionTimeline.replay(entries + relevant)   // 員工事件在前、角色事件在後
        }
        return result
    }

    /// 讀一條員工事件 stream 並轉成時間軸。stream 不存在（或一筆事件都沒有）回 nil；
    /// stream 存在、但沒有任何影響權限的事件時回空陣列（重播結果為空集合）。
    private func readEmployeeEntries(streamName: String, resolveLinks: Bool) async throws -> [TimelineEntry]? {
        let mapper = EmployeeAccessAggregateEventMapper()
        var entries: [TimelineEntry] = []
        var sawEvent = false
        do {
            let responses = try await kdbClient.streams(specified: streamName).read {
                $0.direction = .forward
                $0.revision = .start
                $0.resolveLinks = resolveLinks
            }
            for try await response in responses {
                // 不用 `response.event`（理由同 §c）；非 `.event` 一律 fail-closed。
                guard case let .event(readEvent) = response else {
                    throw PermissionTimelineError.unresolvableEvent(stream: streamName)
                }
                sawEvent = true
                // link stream：`readEvent.record` 是解析後的原始事件，位置取它的（P-a）；
                // link 事件本身與頂層 commitPosition 是 projection 寫入 link 的時間點，晚於原始事件，不可用。
                let record = readEvent.record
                guard let event = try mapper.mapping(eventData: record) else {
                    throw PermissionTimelineError.unmappedEvent(stream: streamName, eventType: record.eventType)
                }
                let position = LogPosition(commit: record.position.commit, prepare: record.position.prepare)
                switch event {
                case let created as UserAccessProfileCreated:
                    entries.append(.init(position: position, event: .profileCreated(permissions: created.permissions, roles: created.roles)))
                case let granted as PrivilegeGranted:
                    entries.append(.init(position: position, event: .privilegeGranted(permissions: Set(granted.permissions))))
                case let revoked as PrivilegeRevoked:
                    entries.append(.init(position: position, event: .privilegeRevoked(permissions: Set(revoked.permissions))))
                case let assigned as RolesAssigned:
                    entries.append(.init(position: position, event: .rolesAssigned(roleIds: Set(assigned.roles))))
                case let revokedRoles as RolesRevoked:
                    entries.append(.init(position: position, event: .rolesRevoked(roleIds: Set(revokedRoles.roles))))
                case is UserPromoted, is DepartmentTransferred, is EmployeeAccessDeleted:
                    continue   // 明確忽略：不影響權限（§d 事件型別處置總表）
                default:
                    throw PermissionTimelineError.unhandledEvent(stream: streamName, eventType: record.eventType)
                }
            }
        } catch KurrentError.resourceNotFound(_) {
            return nil   // 只剩 read 開頭的 streamNotFound：員工不存在（未建檔、projection 未部署）
        }
        return sawEvent ? entries : nil
    }
}
```

- **兩條路徑的差別只有員工事件的來源**：查詢路徑讀 link stream（`resolveLinks: true`，既有 projection，最終一致，延遲與階段二的 `RolesAssigned`／`PrivilegeGranted` 相同）；寫入前置檢查讀原始 stream（`resolveLinks: false`，強一致）。兩者的引擎、角色歷史讀取完全相同。角色事件兩條路徑都直接讀原始 stream（強一致）。
- `GetPermissionsPresenter.getStreamName(id:)` 產生 `IAM_GetPermissions-<userId>`：`EventStreamNaming.getStreamName(id:)`（`.build/checkouts/swift-ddd-kit/Sources/DDDCore/Entity/EventStreamNaming.swift`）＋projector 的 category 規則（`GetPermissionsPresenter.categoryRule = .fromClass(withPrefix: "IAM_")`，category 去掉 "Presenter"，見 `.build/checkouts/swift-ddd-kit/Sources/EventSourcing/Projector/EventSourcingProjector.swift` 的 `category`）；`EmployeeAccess.getStreamName(id:)` 產生 `IAMEmployeeAccess-<id>`（`EmployeeAccess.category` 為 `"IAM\(Self.self)"`）。兩者皆已用本機 KurrentDB 實測。
- 候選人讀取用 `presenter.coordinator.fetchEvents`（DDDKit 既有，stream 不存在回 nil），只取事件裡的 `userId`，不需要位置；KurrentDB 不可用等錯誤向上拋（沿用階段二「窄 catch」精神：只有「stream 不存在」視為空）。**候選人階段不在 fail-closed 範圍**：`fetchEvents` 對解碼失敗只記 warning 並略過，後果是反查少列人（超集合縮小），不會讓 `getPermissions` 給出錯誤權限；逐人重播階段才是 fail-closed。
- `KurrentError.resourceNotFound(_)`：stream 不存在時 `read` 迭代拋出（`.build/checkouts/swift-kurrentdb/Sources/KurrentDB/Streams/Streams.ReadResponse.swift` 的 `streamNotFound` 訊息 → `resourceNotFound`），與 DDDKit `fetchEvents` 的處理（`KurrentStorageCoordinator.fetchEvents` 的 `catch KurrentError.resourceNotFound`）同一型別。單一事件無法解析不走這條（改拋 `PermissionTimelineError.unresolvableEvent`，見 P-a）。
- `effectivePermissions(userIds:)` 的錯誤語意：任何一位候選人的讀取或重播拋錯，整批失敗（不回部分結果）——`getPermissionHolders` 因此在單一員工資料損毀時整體 503，而不是悄悄少列一個人。

### f. `GetPermissionsApplicationService`（修改，`Sources/EmployeeAccessAggregate/Adapter/GetPermissions/GetPermissionsApplicationService.swift`）

init 簽章不變（`init(kdbClient:roleDirectory:debugOverridePermissions:)`），所以 `ApiHandler`、`PermissionsService`、`IAMContextServer` 與既有測試的建構式都不用改。`execute(input:)` 改為（`debugOverridePermissions` 分支之後的整段取代）：

```swift
package func execute(input: Input) async throws -> Output {
    // IAM_DEBUG_FULL_PERMISSIONS=1 — 不變：略過重播，回注入的整個 catalog。
    if let overrides = debugOverridePermissions {
        return overrides
    }
    // 有效權限 = 員工事件與其持有過的角色事件依全域位置重播的結果（D2、D3）。
    let timeline = PermissionTimelineService(kdbClient: kdbClient, roleDirectory: roleDirectory)
    guard let permissions = try await timeline.effectivePermissions(userId: input.userId) else {
        // 員工不存在（link stream 不存在）：沿用既有 notFound 語意，HTTP 404、gRPC 轉空清單。
        throw ContextError<EmployeeAccessQueryError>(
            error: .notFound,
            in: .struct(GetPermissionsApplicationService.self, function: #function),
            message: "employee event stream not found for \(input.userId)"
        )
    }
    return Array(permissions)
}
```

- 不再使用 `GetPermissionsPresenter` 折疊出的 `permissions`／`roles`（該 presenter 仍給 `PermissionScopeFilter` 用 `department`／`firm`）。
- 回傳 `Array(Set)`，順序不保證（與階段二相同，HTTP 契約本來就是無序字串陣列）。

### g. `revokePrivilege` 前置條件放寬（D1；`[inferred]` I-1）

**aggregate**（`Sources/EmployeeAccessAggregate/Entity/Commands/EmployeeAccess+RevokePrivilege.swift` 的 `revokePrivilege(employeeAccessId:userId:permissions:)`）：新增一個帶預設值的參數，前置條件仍留在 aggregate（與 `grantPrivilege` 同一風格），舊呼叫端不受影響：

```swift
package func revokePrivilege(employeeAccessId: String, userId: String, permissions: [String], heldViaOtherSources: Set<String> = []) throws {
    // PRECONDITION：要撤銷的權限須在「直接授權」或「其他來源（角色）持有的有效權限」裡，否則 permissionNotExist。
    // heldViaOtherSources 由 usecase 以強一致重播算出（見下），aggregate 不依賴任何 port。
    let direct = self.permissions ?? []
    if let missing = permissions.first(where: { !direct.contains($0) && !heldViaOtherSources.contains($0) }) {
        throw ContextError<EmployeeAccessError>.permissionNotExist(function: #function, message: "permission \(missing) does not exist for user")
    }
    // IDENTITY GUARD ……（以下不變）
    let event = PrivilegeRevoked(employeeAccessId: self.id, userId: userId, permissions: permissions, occurred: .now)
    try self.apply(event: event)
}
```

同檔的 `when(event: PrivilegeRevoked)` **不變**：`self.permissions` 只追蹤直接授權，對角色來源的權限做差集是 no-op；有效權限由重播負責。

**usecase**（`Sources/EmployeeAccessAggregate/Usecase/Port/In/RevokePrivilege/RevokePrivilegeUsecase.swift`）：

```swift
package protocol RevokePrivilegeUsecase: Usecase where Input == RevokePrivilegeInput, Output == RevokePrivilegeOutput {
    var repository: EmployeeAccessRepository { get }
    var effectivePermissionsReader: EffectivePermissionsReader { get }
}

extension RevokePrivilegeUsecase {
    package func execute(input: RevokePrivilegeInput) async throws -> RevokePrivilegeOutput {
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            // 直接授權裡就有的權限不必重播（與既有行為、時序完全相同，也不會被 projection 延遲誤擋）。
            // 其餘的才用強一致重播（讀員工原始 stream）判斷是否在有效權限裡；都不在 → aggregate 拋 permissionNotExist。
            let notDirect = Set(input.permissions).subtracting(employeeAccess.permissions ?? [])
            var heldViaOtherSources: Set<String> = []
            if !notDirect.isEmpty {
                let effective = try await effectivePermissionsReader.effectivePermissions(employeeAccessId: input.employeeAccessId)
                heldViaOtherSources = notDirect.intersection(effective)
            }
            try employeeAccess.revokePrivilege(employeeAccessId: input.employeeAccessId, userId: input.userId, permissions: input.permissions, heldViaOtherSources: heldViaOtherSources)
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

- `RevokePrivilegeService` 新增 `effectivePermissionsReader` 儲存屬性與必填 init 參數（不給預設值，理由同階段二 `roleDirectory`：預設空實作會默默讓角色來源的撤銷全部被擋）：`init(repository: EmployeeAccessRepository, effectivePermissionsReader: EffectivePermissionsReader)`。
- `RevokePrivilegeApplicationService`（`Adapter/RevokePrivilege/RevokePrivilegeApplicationService.swift` 的 `init(repository:)`）改為 `init(repository: EmployeeAccessRepository, kdbClient: KurrentDBClient, roleDirectory: RoleDirectory)`，內部建 `PermissionTimelineService(kdbClient:roleDirectory:)` 傳給 `RevokePrivilegeService`（檔案需 `import KurrentDB`）。
- `ApiHandler.revokePrivilege`（`Adapter/ApiHandler.swift` 裡 `RevokePrivilegeApplicationService(repository: repository)` 那一行）改為 `RevokePrivilegeApplicationService(repository: repository, kdbClient: kdbClient, roleDirectory: roleDirectory)`。`ApiHandler` 已持有這兩個值，不用改 init。
- **錯誤映射不變**：`permissionNotExist` 仍是 `ContextError<EmployeeAccessError>` → 422（`ApiComponents+EmployeeAccessApiError.swift` 的 `case .permissionNotExist`）；重播讀取失敗（KurrentDB 不可用，或 `PermissionTimelineError`）落到既有 catch-all → `DDDError.executeUsecaseFailed` → `ApiHandler` 映射成 503。`openapi.yaml` 不動（`/employee-access/{employeeAccessId}/revoke-privilege` 的 200／404／422／503 不變）。
- **SSOT 主檔同步**見 §g-2 末項（`revokePrivilege` 與 `grantPrivilege` 一併處理）。

### g-2. `grantPrivilege` 前置條件對齊有效權限（D5 的推論；`[inferred]` I-11）

**問題**：D4 之下，「直接授予 p 且角色 R 也有 p，之後 R 移除 p」→ 員工失去 p（有效權限不含 p），但 `EmployeeAccess.permissions`（直接授權集合，`when(event: PrivilegeGranted)` 累加）仍含 p，於是 `grantPrivilege(p)` 被 aggregate 前置條件擋成 `permissionAlreadyExists`——違反 D5（直接授予能把權限給回來）。修法比照 §g：usecase 以強一致重播判斷，aggregate 以帶預設值的參數承接。

**語意**（`D`＝aggregate 的直接授權集合 `self.permissions`；`E`＝強一致重播出的有效權限；`p` 為請求中的一個權限）：

| 情境 | 舊行為 | 新行為 |
|---|---|---|
| p ∈ D 且 p ∈ E（真的已經有） | `permissionAlreadyExists` | **不變** |
| p ∈ D 但 p ∉ E（直接授權還在帳上，卻因角色被撤銷／移除該權限／刪除而失效） | `permissionAlreadyExists` | **成功**：寫入 `PrivilegeGranted`，重播後 p 回到有效權限（D5） |
| p ∉ D（含「只來自角色」的 p） | 成功 | **不變**（usecase 不重播、不多讀任何東西；階段二既有測試 #4 依賴此行為） |

請求含多個權限時逐個套用上表，任一個落在第一列就整包 `permissionAlreadyExists`（與舊行為一致）。

**aggregate**（`Sources/EmployeeAccessAggregate/Entity/Commands/EmployeeAccess+GrantPrivilege.swift` 的 `grantPrivilege(employeeAccessId:userId:permissions:)`）：

```swift
package func grantPrivilege(employeeAccessId: String, userId: String, permissions: [String], lapsedDirectGrants: Set<String> = []) throws {
    // PRECONDITION：要授予的權限不可「已在直接授權、且仍在有效權限」。
    // lapsedDirectGrants ＝ 在直接授權裡、但已不在有效權限的權限（usecase 以強一致重播算出）；
    // 預設空集合 → 前置條件與舊行為完全相同（任一已在直接授權 → permissionAlreadyExists）。
    let direct = self.permissions ?? []
    guard !permissions.contains(where: { direct.contains($0) && !lapsedDirectGrants.contains($0) }) else {
        throw ContextError<EmployeeAccessError>.permissionAlreadyExists(function: #function, message: "permission already granted to user")
    }
    // IDENTITY GUARD ……（以下不變）
    let event = PrivilegeGranted(employeeAccessId: self.id, userId: userId, permissions: permissions, occurred: .now)
    try self.apply(event: event)
}
```

同檔的 `when(event: PrivilegeGranted)` **不變**（聯集；p 已在集合內時是 no-op）。

**usecase**（`Sources/EmployeeAccessAggregate/Usecase/Port/In/GrantPrivilege/GrantPrivilegeUsecase.swift`）：

```swift
package protocol GrantPrivilegeUsecase: Usecase where Input == GrantPrivilegeInput, Output == GrantPrivilegeOutput {
    var repository: EmployeeAccessRepository { get }
    var effectivePermissionsReader: EffectivePermissionsReader { get }
}

extension GrantPrivilegeUsecase {
    package func execute(input: GrantPrivilegeInput) async throws -> GrantPrivilegeOutput {
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            // 只有「請求的權限裡有已在直接授權的」才需要重播（其餘與既有行為、時序完全相同）。
            // 重播讀員工原始 stream（強一致）；直接授權在但有效權限沒有 → 交給 aggregate 放行。
            let alreadyDirect = Set(input.permissions).intersection(employeeAccess.permissions ?? [])
            var lapsedDirectGrants: Set<String> = []
            if !alreadyDirect.isEmpty {
                let effective = try await effectivePermissionsReader.effectivePermissions(employeeAccessId: input.employeeAccessId)
                lapsedDirectGrants = alreadyDirect.subtracting(effective)
            }
            try employeeAccess.grantPrivilege(employeeAccessId: input.employeeAccessId, userId: input.userId, permissions: input.permissions, lapsedDirectGrants: lapsedDirectGrants)
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

- `GrantPrivilegeService`（`Usecase/Service/GrantPrivilegeService.swift`）新增 `effectivePermissionsReader` 儲存屬性與**必填** init 參數：`init(repository: EmployeeAccessRepository, effectivePermissionsReader: EffectivePermissionsReader)`（理由同 `RevokePrivilegeService`：預設值會讓漏接線的環境靜默回到舊行為）。**所有** `GrantPrivilegeService(repository:)` 呼叫點都要改（編譯器會逐一指出）；驗收標準用負向 grep 確認不留舊寫法。
- `GrantPrivilegeApplicationService`（`Adapter/GrantPrivilege/GrantPrivilegeApplicationService.swift` 的 `init(repository:)`）改為 `init(repository: EmployeeAccessRepository, kdbClient: KurrentDBClient, roleDirectory: RoleDirectory)`，內部建 `PermissionTimelineService(kdbClient:roleDirectory:)` 傳給 `GrantPrivilegeService`（檔案需 `import KurrentDB`）。
- `ApiHandler.grantPrivilege`（`Adapter/ApiHandler.swift` 裡 `GrantPrivilegeApplicationService(repository: repository)` 那一行）改為 `GrantPrivilegeApplicationService(repository: repository, kdbClient: kdbClient, roleDirectory: roleDirectory)`。
- **錯誤映射不變**：`permissionAlreadyExists`、`userIdMismatch` 仍是 `ContextError<EmployeeAccessError>` → 422；`aggregateNotFound` → 404；重播讀取失敗（KurrentDB 不可用，或 `PermissionTimelineError`）→ `executeUsecaseFailed` → 503。`openapi.yaml` 不動（`/employee-access/{employeeAccessId}/grant-privilege` 的 200／404／422／503 不變）。**新增的失敗面**：重播只在「請求的權限已在直接授權」時才發生，所以一般的首次授予完全不受影響；重複授予同一權限時，若重播失敗（角色 stream 讀取失敗，或 `PermissionTimelineError`），原本回 422 `permissionAlreadyExists` 的請求會改回 503——讀取失敗不能被當成「不在有效權限」而放行（fail-closed）。
- **一致性語意**：重播讀員工原始 stream 與角色原始 stream，兩者都不經 projection；員工 stream 與 `repository.find` 讀的是同一條，`find` 到 `save` 之間若有並行的員工事件寫入，`save` 的 expected revision 會擋下（既有行為）。**角色 stream 的並行寫入不在 expected revision 保護內**：重播判定「p 已失效」後、`save` 前若角色又把 p 加回來，會多寫一筆 `PrivilegeGranted`（重播對重複授予冪等，無害）；反向（判定「p 仍有效」而回 `permissionAlreadyExists`，隨後角色移除 p）只需重試一次。見已知限制 #13。
- **SSOT 主檔同步**（專案 `CLAUDE.md`「SSOT discipline」）：由人類授權後更新 `.ai/contexts/IAMContext/EmployeeAccess/` 下三個主檔，沿用 `errors.md` 既有的 `<!-- Added post-... (human-authorized YYYY-MM-DD) -->` 註記慣例，授權日期 2026-09-30（`revokePrivilege` 部分為 D1，`grantPrivilege` 部分為 D5 的推論，使用者於對話中確認）：
  - `commands.md`：`## grantPrivilege` 的 Preconditions 補註「already in」的定義（在直接授權且仍在有效權限）；`## revokePrivilege` 的 Preconditions 改為「權限在直接授權，或在有效權限（例如只由角色供應）」。
  - `errors.md`：`permissionAlreadyExists` 的 Title 補「（在直接授權裡，且仍在有效權限中）」；`permissionNotExist` 的 Title 補「（既不在直接授權，也不在有效權限中）」。
  - `test-scenarios.md`：`Scenario: grantPrivilege`、`Scenario: revokePrivilege` 各補一個 Gherkin 情境（見下），原有情境保留。

    ```gherkin
    Scenario: revokePrivilege of a permission supplied only by a role
      Given the employee holds role R whose permissions include p, and p is not directly granted
      When  revokePrivilege(employeeAccessId, userId, [p])
      Then  emits `privilegeRevoked` and the employee's effective permissions no longer contain p

    Scenario: grantPrivilege of a directly-granted permission that a role removal made ineffective
      Given p is directly granted and also in role R held by the employee, and R later removed p
      When  grantPrivilege(employeeAccessId, userId, [p])
      Then  emits `privilegeGranted` and the employee's effective permissions contain p again
    ```
  - `docs/tasks/grantPrivilege.md`、`docs/tasks/revokePrivilege.md` 是 Genesis 產物（frontmatter 有 `useCase:`），**不手改本文**（`AGENTS.md`）。

### h. `GetPermissionHoldersApplicationService`（修改，D6；`Sources/EmployeeAccessAggregate/Adapter/GetPermissionHolders/GetPermissionHoldersApplicationService.swift`）

init 簽章不變（`init(kdbClient:roleDirectory:)`），`ApiHandler` 與既有測試的建構式不用改。`execute(input:)` 原本的「1. 直接持有者 → 2. 含此權限的角色 → 3. 每個角色的持有者 → 4. 聯集」四步改為「候選人＋逐人重播」；後面「依部門和/或所別過濾」的迴圈只把輸入從 `allUserIds` 換成 `holders`，其餘（`try?` 略過讀不到 read model 的人、`PermissionScopeFilter.matches`）不變：

```swift
package func execute(input: Input) async throws -> Output {
    let timeline = PermissionTimelineService(kdbClient: kdbClient, roleDirectory: roleDirectory)

    // 1. 候選人（超集合）：曾被直接授予者 ∪ 曾持有「任何時候含過該權限的角色」者。
    let candidates = try await timeline.candidateUserIds(permission: input.permission)

    // 2. 每位候選人重播（與 getPermissions 同一套規則）；只留下有效權限含此權限者。
    //    被個別撤銷、或角色已移除／刪除該權限的人在這裡被濾掉。
    let effectiveByUser = try await timeline.effectivePermissions(userIds: candidates)
    let holders = candidates.filter { effectiveByUser[$0]?.contains(input.permission) == true }

    // 3. 未指定任何過濾條件 → 直接回傳（向後相容）。
    guard input.department != nil || input.firm != nil else {
        return holders
    }

    // 4. department／firm 過濾：既有迴圈不變（PermissionScopeFilter 與 CheckScope 共用同一份）。
    let permissionsPresenter = GetPermissionsPresenter(
        coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
    )
    var filtered: [String] = []
    for userId in holders {
        guard let result = try? await permissionsPresenter.execute(input: .init(userId: userId)) else {
            continue
        }
        let readModel = result.readModel
        guard PermissionScopeFilter.matches(readModel: readModel, department: input.department, firm: input.firm) else {
            continue
        }
        filtered.append(userId)
    }
    return filtered
}
```

- 不再使用 `GetRoleHoldersApplicationService`（該 service 仍供 `GET /employee-access/role-holders` 使用，不動）與 `GetPermissionHoldersPresenter` 的折疊結果（presenter 只剩 `coordinator` 被候選人讀取使用）。
- 順序：曾被直接授予者依首次授予順序在前，只經由角色者排序後接在後面，已去重（沿用階段二對外文件的說法，僅「持有者」定義改為重播結果）。
- 成本：每位候選人一次 link stream 讀取，所有候選人共用一次角色歷史讀取（每個相關角色一次 stream 讀取）；候選人上限是全公司員工數（數百人），與既有 department／firm 過濾迴圈同量級，已知限制 #4。

### i. 一致性語意表

| 查詢／操作 | 員工事件來源 | 角色事件來源 | 一致性 | 備註 |
|---|---|---|---|---|
| `getPermissions`（HTTP＋gRPC，`effectivePermissions(userId:)`） | link stream `IAM_GetPermissions-<userId>` | 角色原始 stream `IAMRole-<roleId>` | 角色側強一致；員工側最終一致（projection lag，數百 ms，與階段二相同） | 角色編輯後下一次查詢立即反映（零扇出賣點不變）；對個人撤銷／授予、指派角色後要等 projection 才會進時間軸。**兩側新鮮度不同，合併結果不保證是單一時間點的快照**，見失敗路徑「員工側 projection 延遲」與已知限制 #1 |
| `revokePrivilege` 前置檢查（`effectivePermissions(employeeAccessId:)`） | 原始 stream `IAMEmployeeAccess-<employeeAccessId>` | 同上 | 員工側**強一致**（`save` 的 expected revision 擋並行寫入）；角色側是讀取當下的狀態，**不與 `save` 原子化**（已知限制 #13） | 僅在請求的權限有不在直接授權者時才重播；全在直接授權時完全不讀 |
| `grantPrivilege` 前置檢查（同一個 `effectivePermissions(employeeAccessId:)`） | 同上 | 同上 | 同上 | 僅在請求的權限有已在直接授權者時才重播；全不在直接授權時完全不讀（§g-2） |
| `getPermissionHolders` 候選人 | `IAM_GetPermissionHolders-<permission>`、`IAM_GetRoles-all`、`IAM_GetRoleHolders-<roleId>` | — | 最終一致 | 候選人只是超集合，決定「要重播誰」；誰算持有者由重播決定 |
| `getPermissionHolders` 逐人重播 | 同 `getPermissions` | 同 `getPermissions` | 同 `getPermissions` | 反查與 `getPermissions` 同一套規則（D6） |
| `assignRoles` 存在性驗證（`resolve`） | — | rehydrate（`find(byId:)`） | 強一致 | 不變 |
| 消費端快取 | — | — | 60 秒（正）／10 秒（空） | 不變（D7） |

### j. 測試替身（`Tests/IAMContextTests/FakeRoleDirectory.swift`，修改）

```swift
import EmployeeAccessAggregate

struct FakeRoleDirectory: RoleDirectory {
    private let resolved: [String: Set<String>]?
    private let everContaining: [String: Set<String>]
    private let histories: [String: [TimelineEntry]]

    /// - `resolved`／`histories` 二選一或並用：`histories[roleId]` 有值就照它回（可自訂位置與事件，模擬刪除等）；
    ///   否則沿用階段二語意由 `resolved` 合成歷史。
    init(resolved: [String: Set<String>]? = nil,
         everContaining: [String: Set<String>] = [:],
         histories: [String: [TimelineEntry]] = [:]) {
        self.resolved = resolved
        self.everContaining = everContaining
        self.histories = histories
    }

    func resolve(roleIds: Set<String>) async throws -> [String: Set<String>] { /* 不變 */ }

    /// 合成歷史：位置 `LogPosition(commit: 0, prepare: 0)` 的 `roleCreated` ＋（權限非空時）`rolePermissionsAdded`，
    /// 因此永遠早於任何真實事件（真實位置 > 0）。permissive 模式（`resolved == nil`）用哨兵權限
    /// `"__fake_permission_from_<roleId>__"`，與 `resolve` 一致；顯式模式下不在 `resolved` 的 roleId 不產生 entry。
    func history(ofRoles roleIds: Set<String>) async throws -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        for roleId in roleIds.sorted() {
            if let explicit = histories[roleId] { entries += explicit; continue }
            let permissions: Set<String>
            if let resolved {
                guard let known = resolved[roleId] else { continue }
                permissions = known
            } else {
                permissions = ["__fake_permission_from_\(roleId)__"]
            }
            let origin = LogPosition(commit: 0, prepare: 0)
            entries.append(.init(position: origin, event: .roleCreated(roleId: roleId)))
            if !permissions.isEmpty {
                entries.append(.init(position: origin, event: .rolePermissionsAdded(roleId: roleId, permissions: permissions)))
            }
        }
        return entries
    }

    func rolesEverContaining(permission: String) async throws -> Set<String> {
        everContaining[permission] ?? []
    }
    // rolesContaining(permission:) 與 `containing` 參數：Step 5 刪除（在此之前保留，讓每一步都能編譯）。
}
```

`ReadSideServiceUnavailableTests.swift` 內私有的 `ThrowingRoleDirectory`（檔案尾端 `// MARK: - helpers` 區）同步：新增 `history(ofRoles:)`、把 `rolesContaining` 換成 `rolesEverContaining`，兩者都 `throw Failure()`；「RoleDirectory 出錯 → 503」那一節開頭註解裡的 `rolesContaining` 字樣改為 `rolesEverContaining`。

---

## 改動檔案

### 新增

| 檔案 | 說明 |
|---|---|
| `Sources/EmployeeAccessAggregate/Entity/PermissionTimeline/PermissionTimeline.swift` | `LogPosition`／`TimelineEvent`／`TimelineEntry`／`PermissionTimelineError`／`PermissionTimeline.replay`／`mentionedRoleIds`（介面合約 §a、§d） |
| `Sources/EmployeeAccessAggregate/Usecase/Port/Out/EffectivePermissionsReader.swift` | 供 `RevokePrivilegeUsecase`、`GrantPrivilegeUsecase` 用的出埠（介面合約 §e） |
| `Sources/EmployeeAccessAggregate/Adapter/PermissionTimeline/PermissionTimelineService.swift` | 員工側時間軸讀取、批次重播、D6 候選人發現（介面合約 §e） |
| `Tests/IAMContextTests/PermissionTimelineTests.swift` | 重播引擎純單元測試（18 條，不需要 KurrentDB，見驗收標準） |
| `docs/tasks/registry/permission-timeline-composition.json` | 本 task 的 registry 條目 |

### 修改

| 檔案 | 改動描述 |
|---|---|
| `Sources/EmployeeAccessAggregate/Usecase/Port/Out/RoleDirectory.swift` | 新增 `history(ofRoles:)`、`rolesEverContaining(permission:)`；Step 5 刪除 `rolesContaining(permission:)`（介面合約 §b） |
| `Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift` | 實作 `history`、`rolesEverContaining`；新增 3 行具名 import；Step 5 刪除 `rolesContaining` 並改寫檔頭 doc 註解（介面合約 §c） |
| `Sources/EmployeeAccessAggregate/Adapter/GetPermissions/GetPermissionsApplicationService.swift` | `execute` 改用 `PermissionTimelineService`（介面合約 §f） |
| `Sources/EmployeeAccessAggregate/Adapter/GetPermissionHolders/GetPermissionHoldersApplicationService.swift` | `execute` 前四步改為候選人＋逐人重播；department／firm 過濾迴圈只換輸入（介面合約 §h） |
| `Sources/EmployeeAccessAggregate/Entity/Commands/EmployeeAccess+RevokePrivilege.swift` | `revokePrivilege` 新增 `heldViaOtherSources: Set<String> = []`，前置條件放寬（介面合約 §g） |
| `Sources/EmployeeAccessAggregate/Usecase/Port/In/RevokePrivilege/RevokePrivilegeUsecase.swift` | 協定新增 `effectivePermissionsReader`；`execute` 加強一致的重播前置檢查（介面合約 §g） |
| `Sources/EmployeeAccessAggregate/Usecase/Service/RevokePrivilegeService.swift` | 新增 `effectivePermissionsReader` 儲存屬性＋必填 init 參數 |
| `Sources/EmployeeAccessAggregate/Adapter/RevokePrivilege/RevokePrivilegeApplicationService.swift` | init 改為 `(repository:kdbClient:roleDirectory:)`，內部建 `PermissionTimelineService`；新增 `import KurrentDB` |
| `Sources/EmployeeAccessAggregate/Entity/Commands/EmployeeAccess+GrantPrivilege.swift` | `grantPrivilege` 新增 `lapsedDirectGrants: Set<String> = []`，前置條件對齊有效權限（介面合約 §g-2） |
| `Sources/EmployeeAccessAggregate/Usecase/Port/In/GrantPrivilege/GrantPrivilegeUsecase.swift` | 協定新增 `effectivePermissionsReader`；`execute` 在「請求的權限已在直接授權」時加強一致的重播（介面合約 §g-2） |
| `Sources/EmployeeAccessAggregate/Usecase/Service/GrantPrivilegeService.swift` | 新增 `effectivePermissionsReader` 儲存屬性＋必填 init 參數 |
| `Sources/EmployeeAccessAggregate/Adapter/GrantPrivilege/GrantPrivilegeApplicationService.swift` | init 改為 `(repository:kdbClient:roleDirectory:)`，內部建 `PermissionTimelineService`；新增 `import KurrentDB` |
| `Sources/EmployeeAccessAggregate/Adapter/ApiHandler.swift` | 只改 `revokePrivilege` 與 `grantPrivilege` 兩個 handler：建構對應 `...ApplicationService` 時多傳 `kdbClient`、`roleDirectory`；其餘 handler 不動 |
| `.ai/contexts/IAMContext/EmployeeAccess/commands.md`、`errors.md`、`test-scenarios.md` | SSOT 主檔同步 `revokePrivilege` 放寬、`grantPrivilege` 對齊有效權限（介面合約 §g-2 末項；人類授權 2026-09-30） |
| `docs/integration/2026-09-24-role-api-update.html` | D7：更新行為說明，見 Step 8 逐處清單 |
| `Tests/IAMContextTests/FakeRoleDirectory.swift` | 新增 `history`、`rolesEverContaining`、`histories`／`everContaining` 參數（介面合約 §j）；Step 5 刪除 `rolesContaining`／`containing` 並改寫檔頭 doc 註解 |
| `Tests/IAMContextTests/ReadSideServiceUnavailableTests.swift` | `ThrowingRoleDirectory` 同步新方法；「RoleDirectory 出錯 → 503」節開頭的註解字樣 |
| `Tests/IAMContextTests/GrantPrivilegeIntegrationTests.swift` | 全部 `GrantPrivilegeService(repository:)` 呼叫點（撰寫時 4 處）改為多傳 `effectivePermissionsReader`；斷言不變（含 `grant_existing_privilege_throws`） |
| `Tests/IAMContextTests/RevokePrivilegeIntegrationTests.swift` | 全部 `RevokePrivilegeService(repository:)`（撰寫時 3 處）與 `GrantPrivilegeService(repository:)`（撰寫時 1 處）呼叫點多傳 `effectivePermissionsReader`；斷言不變 |
| `Tests/IAMContextTests/GetPermissionHoldersIntegrationTests.swift` | 全部 `GrantPrivilegeService(repository:)`（撰寫時 12 處）與 `RevokePrivilegeService(repository:)`（撰寫時 1 處）呼叫點同上；其餘斷言不變（8 條測試） |
| `Tests/IAMContextTests/RolePermissionCompositionIntegrationTests.swift` | 反轉 #4；全部 `GrantPrivilegeService(repository:)` 呼叫點（撰寫時 4 處）多傳 `effectivePermissionsReader`；「等 GetRoles projection」註解字樣（含 `rolesContaining`）更新；新增 helper 與 15 條測試 #13–#27 |

呼叫點的修改一律是機械替換：各測試檔加一個 private computed property（例如 `private var timeline: PermissionTimelineService { PermissionTimelineService(kdbClient: kdbClient, roleDirectory: FakeRoleDirectory()) }`；`RolePermissionCompositionIntegrationTests` 用真的 `directory`），呼叫點改為 `GrantPrivilegeService(repository: repository, effectivePermissionsReader: timeline)`。Step 6 的負向 grep（`GrantPrivilegeService(repository: <識別字>)` 與 `RevokePrivilegeService(repository: <識別字>)` 皆無命中）保證不漏。

**不需要修改**（列出以免漏改的疑慮）：`Package.swift`（無新依賴、無新 target；`EmployeeAccessAggregate` 已依賴 DDDKit（含 KurrentDB）與 `IAMContextShared`）；`Sources/IAMContextServer/IAMContextServer.swift`（建立 `RoleAggregateDirectory(kdbClient:)` 並注入 `ApiHandler` 與 `PermissionsService` 兩處的寫法不變，`RoleAggregateDirectory` 本來就符合擴充後的 `RoleDirectory`）；`Sources/IAMContextServer/PermissionsService.swift`（`GetPermissionsApplicationService` init 簽章不變）；`EmployeeAccessAggregate.ApiHandler` 的 init（已持有 `kdbClient`、`roleDirectory`）；`Sources/EmployeeAccessAggregate/openapi.yaml` 與 `Sources/EmployeeAccessAggregate/EmployeeAccessError.swift`（沒有新 HTTP 錯誤碼；`PermissionTimelineError` 是內部錯誤，經 catch-all 映射成 503）。

### 預期反轉的既有測試（逐一查證，`/usr/bin/grep` 全 repo `Tests/`）

**A. 反轉（1 條）**

| 檔案 | 測試名 | 舊預期 | 新預期 |
|---|---|---|---|
| `Tests/IAMContextTests/RolePermissionCompositionIntegrationTests.swift` | `permission_from_both_direct_grant_and_role_remains_after_role_removes_it`（階段二 #4） | 角色移除該權限後，員工**仍有**該權限（階段二「任一來源移除都不影響另一來源」） | **反轉**（D4）：改名為 `permission_from_both_direct_grant_and_role_is_lost_when_role_removes_it`；「移除前含該權限」的前置斷言不變；移除後的最後一個斷言改為 `#expect(!(try await httpPermissions(userId: userId, directory: directory).contains(permission)))`，並補 gRPC 入口的同一斷言 |

**B. 斷言錯誤碼的既有測試——新規則下仍成立（全 repo `Tests/` 內 `permissionAlreadyExists`／`permissionNotExist` 的斷言只有這兩條；`/usr/bin/grep -rn "permissionAlreadyExists\|permissionNotExist" Tests` 只會命中這兩個檔案）**

| 檔案 | 測試名 | 斷言 | 新規則下為何仍成立 | 需要的修改 |
|---|---|---|---|---|
| `Tests/IAMContextTests/GrantPrivilegeIntegrationTests.swift` | `grant_existing_privilege_throws` | 同一權限授予兩次，第二次 `permissionAlreadyExists` | 第二次時 p ∈ D（第一次的 `PrivilegeGranted`）；usecase 重播員工原始 stream，`PrivilegeGranted` 使 p ∈ E → `lapsedDirectGrants` 為空 → aggregate 前置條件照舊擋下（§g-2 語意表第一列）。角色歷史不會被讀（員工沒有任何角色） | 只有建構式（多傳 `effectivePermissionsReader`） |
| `Tests/IAMContextTests/RevokePrivilegeIntegrationTests.swift` | `revoke_missing_privilege_throws` | 撤銷 `"custom:new"` → `permissionNotExist` | `[inferred]` I-1：放寬後仍要求「在直接授權或有效權限裡」，`"custom:new"` 兩者皆非，仍回 `permissionNotExist`。**要反轉的是「只來自角色的權限」這個情境，而全 repo 沒有任何既有測試斷言它**，所以由新測試 #13 承接。若使用者改裁決為「完全不檢查」，本測試才需改為「成功並寫入 `PrivilegeRevoked`」 | 只有建構式 |

**C. 其餘既有測試的預期不變**（已逐條對照新規則；範圍以此 grep 為準——`/usr/bin/grep -rlE "GrantPrivilegeService|RevokePrivilegeService|RoleDirectory|getPermissions|getPermissionHolders|GetPermissionsApplicationService|GetPermissionHoldersApplicationService|permissionAlreadyExists|permissionNotExist|PermissionsService|EmployeeAccessAggregate.ApiHandler" Tests` 撰寫時命中 12 個檔案，除上面 A、B 與已在改動表列出的檔案外，其餘只用 `FakeRoleDirectory()` 或角色 HTTP 端點，不觸及有效權限計算）：`RolePermissionCompositionIntegrationTests` 的 #1、#2（零扇出）、#3、#5、#6、#7（舊字串：角色 stream 不存在→零貢獻）、#8（`FakeRoleDirectory(resolved:)` 由合成歷史滿足）、#9（反查：候選人來自曾持有者，重播決定；角色移除 p 後被濾掉，不再依賴 projection 等待）、#10、#11、#12（直接授權 d 不在被撤銷角色內，故不受影響）；`GetPermissionHoldersIntegrationTests` 全部 8 條；`GetPermissionsIntegrationTests`（員工不存在→notFound／gRPC 空清單）、`DebugFullPermissionsTests`（debug 分支不重播）、`AssignRolesIntegrationTests`、`RevokeRolesIntegrationTests`、`RoleIntegrationTests`、`RoleApiHandlerIntegrationTests`、`ReadSideServiceUnavailableTests` 的 4 條（KurrentDB 不可達仍在候選人第一段即失敗、`ThrowingRoleDirectory` 仍在第二段失敗，兩者都是 503）。

### 受影響呼叫端（不需修改，列出供 review）

- `OpportunityContext/Sources/OpportunityContext/IAMClient/IAMHTTPPermissionHoldersClient.swift`、`mendesky-web/src/app/features/quoting-cases/components/select-allocator-modal/select-allocator-modal.component.ts`——都吃 `GET /employee-access/permission-holders`，回應形狀不變（`[String]`）；行為變化：被個別撤銷、或角色已移除該權限的人不再出現。人工驗證見 Human 補做。
- `Middleware/Sources/Middleware/PermissionAuthorization/{PermissionMiddleware,CachingPermissionsProvider}.swift`、`AuditContext/Sources/AuditContextServer/main.swift`——gRPC `getPermissions` 回應形狀不變，快取層無感知。
- IAM console（前端）——`revoke-privilege` 對只來自角色的權限由 422 改為 200；`grant-privilege` 對「直接授權還在帳上、但已因角色移除而失效」的權限由 422 改為 200；HTTP 形狀與錯誤碼表不變，但 console 若有「這個權限不是直接授權所以不能移除」或「已有此權限不能再授予」的前端限制，需要知道可以放開（記錄於 D7 的文件更新）。

---

## 實作步驟

> 每一步結尾都跑 `/usr/bin/swift build`（涉及測試檔的步驟另跑 `/usr/bin/swift build --build-tests`）。**本機 shell 的 `grep`、`diff`、`swift`、`git diff` 被包裝過，會印出不實的摘要（例如「Files are identical」）**——本規格所有指令一律寫 `/usr/bin/grep`、`/usr/bin/diff`、`/usr/bin/swift`、`/usr/bin/git`，並以退出碼與實際輸出行判斷，不採信摘要文字。

### Step 0：前置與基線（不改檔）

1. 確認 `docs/tasks/role-permission-composition.md` 已實作（registry 狀態 `done`）。起點工作樹已有本 task 之外的未 commit 變更（`Sources/RoleAggregate/Entity/Role.swift`、`Sources/RoleAggregate/Usecase/Port/In/CreateRole/CreateRoleUsecase.swift`、`Tests/IAMContextTests/RolePermissionCompositionIntegrationTests.swift`、`docs/tasks/role-aggregate.md`、以及未追蹤的 `ReadSideServiceUnavailableTests.swift`、`RoleApiHandlerIntegrationTests.swift`）：**不得 revert 或順手格式化它們**；本 task 對後兩個測試檔與 `RolePermissionCompositionIntegrationTests.swift` 只做列在改動檔案表的修改。
2. 存基線（存在 repo 之外，驗收標準會比對）：

   ```bash
   mkdir -p /tmp/permission-timeline-baseline
   /usr/bin/git diff -- Sources/RoleAggregate/Entity Sources/RoleAggregate/Usecase > /tmp/permission-timeline-baseline/role-internal.diff
   /usr/bin/swift build && /usr/bin/swift build --build-tests
   /usr/bin/swift test 2>&1 | tee /tmp/permission-timeline-baseline/swift-test.log | /usr/bin/grep -E "Test run with [0-9]+ tests"
   ```
   基線必須全綠（該行含 `passed`）；記下其中的測試總數（驗收標準用它核對新增的 33 條）。
3. 確認四支 projection 已部署且在跑（**不要**用 `bash scripts/projection.sh` 當檢查——它對 `projections/` 全部檔案做 disable → delete（含 `deleteEmittedStreams=true`）→ create 的破壞性重建，重建期間 `IAM_GetPermissions-*` link stream 是空的）：

   ```bash
   for n in IAM_GetPermissions IAM_PermissionHolders IAM_RoleHolders IAM_GetRoles; do
     curl -sf -u "${KDB_USER}:${KDB_PASS}" "${KDB_URL:-http://localhost:2113}/projections/any" \
       | jq -e --arg n "$n" '.projections[] | select(.name == $n and .status == "Running")' > /dev/null \
       || { echo "projection $n 不在或未 Running"; exit 1; }
   done
   ```
   任何一支缺失才需要 `bash scripts/projection.sh`（或到 KurrentDB UI 單獨建立該支），部署後重跑此檢查。
4. 重跑 P-a 位置實測（KurrentDB 需在 `localhost:2113`；`<userId>` 用任一已建檔且有事件的員工，例如先跑一次 `RolePermissionCompositionIntegrationTests` 產生的資料）：

   ```bash
   cd .build/checkouts/swift-kurrentdb/proto
   B=$(printf %s "IAM_GetPermissions-<userId>" | base64)
   echo "{\"options\":{\"stream\":{\"stream_identifier\":{\"stream_name\":\"$B\"},\"start\":{}},\"read_direction\":\"Forwards\",\"resolve_links\":true,\"count\":100,\"no_filter\":{},\"uuid_option\":{\"string\":{}}}}" \
     | grpcurl -plaintext -import-path . -proto kurrentdb/v1/streams.proto -d @ localhost:2113 event_store.client.streams.Streams/Read
   ```
   預期：每筆的 `event.event.commitPosition`（原始）**小於** `event.link.commitPosition`，頂層 `event.commitPosition` 等於 link 的，且 `event.event.streamIdentifier.streamName`（base64）解碼為 `IAMEmployeeAccess-…`。不成立就停下，回報使用者（P-a 前提失效，設計要改）。
5. 確認 P-b：任取一個已刪除角色（`$ce-IAMRole` 裡 `RoleDeleted` 的 stream），用同一個 grpcurl 讀它的原始 stream，事件完整且最後一筆是 `RoleDeleted`。

### Step 1：純函式引擎＋單元測試

1. 建立 `Sources/EmployeeAccessAggregate/Entity/PermissionTimeline/PermissionTimeline.swift`（介面合約 §a）。
2. 建立 `Tests/IAMContextTests/PermissionTimelineTests.swift`（18 條，見驗收標準；純 Swift Testing，不連 KurrentDB）。
3. `/usr/bin/swift build` 綠；`/usr/bin/swift test --filter PermissionTimelineTests` 綠。

### Step 2：`RoleDirectory` 新方法＋角色端實作＋測試替身

1. `RoleDirectory.swift` 新增 `history(ofRoles:)`、`rolesEverContaining(permission:)`（**保留** `rolesContaining`，介面合約 §b）。
2. `RoleAggregateDirectory.swift` 實作兩個新方法、補 3 行具名 import（介面合約 §c）。
3. `FakeRoleDirectory.swift`（介面合約 §j）與 `ReadSideServiceUnavailableTests.swift` 的 `ThrowingRoleDirectory` 補新方法（否則測試 target 編不過）。
4. `/usr/bin/swift build` 與 `/usr/bin/swift build --build-tests` 綠（此時新方法尚無人呼叫，只求編譯通過）。

### Step 3：`EffectivePermissionsReader`＋`PermissionTimelineService`

1. 建立 `Usecase/Port/Out/EffectivePermissionsReader.swift`、`Adapter/PermissionTimeline/PermissionTimelineService.swift`（介面合約 §e）。
2. `/usr/bin/swift build` 綠（此時尚無人使用）。

### Step 4：`getPermissions` 切換

1. `GetPermissionsApplicationService.execute` 改用 `PermissionTimelineService`（介面合約 §f）。
2. `/usr/bin/swift build` 綠；`/usr/bin/swift test --filter GetPermissionsIntegrationTests`、`--filter DebugFullPermissionsTests`、`--filter RolePermissionCompositionIntegrationTests`（此時 #4 預期紅——它斷言舊行為，於 Step 7 反轉；階段二其餘 11 條必須綠，證明「換算法、既有行為不變」）。

### Step 5：`getPermissionHolders` 切換＋移除 `rolesContaining`

1. `GetPermissionHoldersApplicationService.execute` 改為候選人＋逐人重播（介面合約 §h）。
2. 從 `RoleDirectory.swift`、`RoleAggregateDirectory.swift`、`FakeRoleDirectory.swift`（`rolesContaining`／`containing`）、`ThrowingRoleDirectory` 刪除 `rolesContaining`；`/usr/bin/grep -rn "rolesContaining" Sources Tests` 必須無輸出——含註解：`RolePermissionCompositionIntegrationTests` 內 #9「等 GetRoles projection」那行註解、`ReadSideServiceUnavailableTests` 的節首註解、`RoleAggregateDirectory` 與 `FakeRoleDirectory` 檔頭的 doc 註解都要一併改寫（介面合約 §j 的範例省略了檔頭註解，實作時檔頭的 `containing`／`rolesContaining` 說明改成 `everContaining`／`rolesEverContaining`）。
3. `/usr/bin/swift build` 與 `--build-tests` 綠；`--filter GetPermissionHoldersIntegrationTests`、`--filter ReadSideServiceUnavailableTests` 綠；`--filter RolePermissionCompositionIntegrationTests` 中 #9（反查）仍綠（#4 仍預期紅，Step 7 反轉）。

### Step 6：`revokePrivilege` 放寬與 `grantPrivilege` 對齊

1. `revokePrivilege`：aggregate、`RevokePrivilegeUsecase`、`RevokePrivilegeService`、`RevokePrivilegeApplicationService`、`ApiHandler.revokePrivilege` 依介面合約 §g 修改。
2. `grantPrivilege`：aggregate、`GrantPrivilegeUsecase`、`GrantPrivilegeService`、`GrantPrivilegeApplicationService`、`ApiHandler.grantPrivilege` 依介面合約 §g-2 修改。
3. 補齊測試呼叫點（改動檔案表的機械替換）：`/usr/bin/grep -rnE "(Grant|Revoke)PrivilegeService\(repository: [A-Za-z]+\)" Tests` 必須無輸出。
4. 同步三個 SSOT 主檔（`.ai/contexts/IAMContext/EmployeeAccess/`，介面合約 §g-2 末項）。
5. `/usr/bin/swift build` 與 `--build-tests` 綠；`--filter RevokePrivilegeIntegrationTests`、`--filter GrantPrivilegeIntegrationTests`、`--filter GetPermissionHoldersIntegrationTests` 綠（權限不在直接授權的路徑不重播，行為與時序與先前完全相同）。

### Step 7：整合測試

1. `RolePermissionCompositionIntegrationTests.swift`：反轉 #4（見「預期反轉」表 A）；新增 helper（`revokePrivilege`／`grantPrivilege` 走 `ApiHandler` 或以 `PermissionTimelineService(kdbClient: kdbClient, roleDirectory: directory)` 為 `effectivePermissionsReader` 建構 Service；`revokeRoles`／`assignRoles` 直接用既有 Service）；新增 #13–#27（見驗收標準清單）。組織對照既有 #1–#12：`@Suite(.serialized)`、`withTestBundle` id 隔離、員工事件之後 `waitForProjection()`、角色事件之後**不等待**。
2. 再跑一次 Step 0 第 3 項的 projection 檢查（本 task 不新增 projection，也不重建）。
3. `/usr/bin/swift build --build-tests` 綠；`/usr/bin/swift test --filter RolePermissionCompositionIntegrationTests` 全綠（27 條：既有 12 條〔#4 已反轉〕＋新增 15 條）。

### Step 8：更新對外文件（D7）

編輯 `docs/integration/2026-09-24-role-api-update.html`，以下用**語意錨點**（章節標題、既有文字片段）定位，不用行號：

1. 「一、一頁摘要」第二項（`<b>3 個既有端點行為改變，形狀不變。</b>`）→ 「5 個」，並補上：`revoke-privilege` 現在可撤銷只來自角色的權限；`grant-privilege` 現在可再授予「直接授權還在帳上、但已因角色移除而失效」的權限。
2. 「四、既有端點的變化」中 `GET /employee-access/permissions/{userId}` 那段說明：把「內容變成 **直接授權 ∪ 該員工每個角色的權限**，已去重」改為「內容是把該員工的事件與他持有過的每個角色的事件依發生順序重播的結果，最新的事件說了算」；其餘（已去重、解析不到的 roleId 貢獻零權限、員工不存在 404／gRPC 空清單、HTTP 與 gRPC 同一段程式）保留。
3. 同一段緊接的 `<div class="note">`（原文含「任一來源移除都不影響另一來源」）：**整句移除**，改為三點：(a) 同一權限同時來自直接授權與角色時，角色被撤銷、移除該權限或刪除，這個權限會一起消失（直接授權不保留）；(b) 同一權限存在於兩個角色時，其中一個被撤銷、移除該權限或刪除，另一個仍供應它；(c) 對個人撤銷的權限，之後只要再被直接授予、重新指派角色、或角色再次加入該權限，就會回來。
4. 該 `<div class="note">` 之後、`assign-roles` 的 `<h3>` 之前，新增兩個 `<h3>`：
   - `<h3><span class="m post">POST</span>/employee-access/{employeeAccessId}/revoke-privilege</h3>`：**行為改變**——撤銷只來自角色的權限現在回 200（原本 422 `permissionNotExist`），該員工事後的有效權限不含它（HTTP 與 gRPC 一致；經 projection 有數百毫秒延遲，消費端最多再晚 60 秒）；錯誤碼不變：422 `permissionNotExist`（該權限既不在直接授權、也不在有效權限）、422 `userIdMismatch`、404 `aggregateNotFound`、503。
   - `<h3><span class="m post">POST</span>/employee-access/{employeeAccessId}/grant-privilege</h3>`：**行為改變**——權限「在直接授權裡、但已因角色被撤銷／移除該權限／刪除而不在有效權限」時，現在可再授予（原本 422 `permissionAlreadyExists`），授予後有效權限含它；權限真的已在有效權限時仍回 422 `permissionAlreadyExists`；其餘錯誤碼不變（422 `userIdMismatch`、404 `aggregateNotFound`、503）。
5. 「四、既有端點的變化」中 `GET /employee-access/permission-holders` 說明：補「持有者以與 `getPermissions` 相同的重播結果判定；被個別撤銷、或角色已移除／刪除該權限的人不會出現」；順序、department／firm 過濾、projection 延遲的說法保留。
6. 「七、相容性與部署」補一句：既有資料不需遷移，但角色曾移除某員工同時直接持有的權限者，有效權限會與舊版聯集結果不同（D4）。
7. 保持 `docs/integration/` 其餘結構與樣式不動；純文字更新，不新增外部資源。
8. `/usr/bin/swift build` 綠（純文件變更，僅確認未動到 `Sources/`）。

### Step 9：全套回歸與收尾

1. `/usr/bin/swift build`、`/usr/bin/swift build --build-tests`、`/usr/bin/swift test` 全綠；總數＝Step 0 基線 ＋ 33（18 單元 ＋ 15 整合；反轉 #4 只是改名，不增減）。
2. 逐條跑驗收標準的契約 grep 與回歸 diff。
3. 更新 `docs/tasks/registry/permission-timeline-composition.json`（`status` 依流程推進，`status_history` 追加，不 commit）。

---

## 失敗路徑

- **`revokePrivilege`：對個人撤銷的權限既不在直接授權、也不在有效權限**：aggregate 拋 `permissionNotExist` → 422。可恢復（沿用既有錯誤，D1 `[inferred]`）。
- **`grantPrivilege`：權限已在直接授權、且仍在有效權限**：aggregate 拋 `permissionAlreadyExists` → 422（與舊行為相同，§g-2 語意表第一列）。權限已在直接授權、但不在有效權限 → 成功；權限不在直接授權 → 成功（不重播）。
- **`revokePrivilege`／`grantPrivilege` 的前置重播讀取失敗**（角色 stream 讀取失敗、`PermissionTimelineError`；KurrentDB 完全不可用時更早在 `repository.find` 就失敗）：非 domain error → `DDDError.executeUsecaseFailed` → `ApiHandler` 映射 503。**不寫入任何事件**（重播在 `repository.save` 之前）；不會把讀取失敗當成「不在有效權限」而放行或擋下。
- **`getPermissions` 的員工不存在**（`IAM_GetPermissions-<userId>` stream 不存在，或一筆事件都沒有）：`ContextError<EmployeeAccessQueryError>.notFound` → HTTP 404、gRPC 回空清單（`PermissionsService.getPermissions` 的既有 catch 分支，不改）。此時完全不讀任何角色 stream。stream 存在但沒有任何影響權限的事件 → 200 空清單。
- **員工持有的 roleId 沒有對應 stream**（歷史舊字串、從未建立）：`history` 對該 roleId 不產生 entry → 零權限貢獻、不報錯（階段二測試 #7 的語意保留）。
- **員工指派角色之後，該角色被刪除**：`RoleDeleted` 在時間軸上把角色內容清空並從 `S` 移除（扣掉其他角色仍供應者）；員工的 `roles` 仍含該 roleId（懸空引用），之後對它的撤銷或再指派都不影響 `S`。
- **fail-closed（`[inferred]` I-5、I-12）**——下列任一情況，重播整體失敗，`getPermissions` HTTP 503／gRPC `.aborted`，`getPermissionHolders` 整體 503，`revokePrivilege`／`grantPrivilege` 503 且不寫事件；不略過該事件、不回部分結果：
  - 讀取回應不是可用事件（link 指向的原始事件已不存在，例如有人 `purge` 了某個 stream）→ `PermissionTimelineError.unresolvableEvent`；
  - 事件無法解碼（`EventTypeMapper.mapping` 拋錯）→ 原樣向上拋；
  - mapper 回 `nil`（eventType 不在對照表，或內容不是 JSON）→ `unmappedEvent`；
  - 事件型別解得出、但不在時間軸的「處理」或「明確忽略」清單（§d 事件型別處置總表）→ `unhandledEvent`。
  - 注意：這會讓「員工或角色 stream 裡混進一筆未登記型別的事件」從過去的靜默略過變成 503。這是刻意的（權限系統寧可拒絕也不猜測）；上線前的資料比對（Human 補做）要先確認現有資料沒有這類事件。
- **員工側 projection 延遲**：對個人撤銷／授予、指派角色的事件要等 `IAM_GetPermissions-<userId>` 連結後才進時間軸，期間 `getPermissions` 看到的是「這些員工事件還沒發生」的狀態。**員工側與角色側新鮮度不同**（員工側落後數百 ms、角色側是當下），所以合併結果在這個視窗內**不保證是單一時間點的快照**——例如員工剛被撤銷角色 R（事件尚未連結）而 R 恰在這段時間新增權限 q，查詢仍會看到 R 持有並含 q。這與階段二相同（階段二同樣是「落後的員工 roles」配「當下的角色內容」），不是新退化；`revokePrivilege`／`grantPrivilege` 的前置檢查讀員工原始 stream，員工側是當下，不受 projection 延遲影響（角色側的並行編輯見已知限制 #13）。
- **反查時 `IAM_GetPermissionHolders`／`IAM_GetRoles`／`IAM_GetRoleHolders` 任一 projection 未部署**：對應候選人來源為空（`fetchEvents` 回 nil）→ 候選人變少，不報錯；退化程度見已知限制 #3。KurrentDB 不可用則 503。
- **候選人的員工 stream 不存在**：該候選人被略過（不在重播結果字典裡）。
- **`rolesEverContaining` 拋錯（測試中的 `ThrowingRoleDirectory`）**：`getPermissionHolders` → 503（候選人第一段讀成功後才呼叫 directory，既有測試 `get_permission_holders_returns_503_when_role_directory_throws` 保護）。
- **`addPermissions`／`removePermissions`／`assignRoles` 等既有驗證**：不變。

---

## 不改動的部分

- **RoleAggregate 內部**（`Entity/`、`Usecase/Port/In/`、`Usecase/Service/`、`Usecase/Projector/`、`event.yaml`、`openapi.yaml`、`projection-model.yaml`、`RoleError.swift`）——本 task 只改 `Adapter/RoleDirectory/RoleAggregateDirectory.swift`。
- **`EmployeeAccess` 與 `Role` 的事件定義**（兩個 `event.yaml`）——不新增事件（D1），不改 schema。`EmployeeAccess+AssignRoles.swift`／`+RevokeRoles.swift` 完全不動；`EmployeeAccess+RevokePrivilege.swift`、`+GrantPrivilege.swift` 只改前置條件（兩者的 `when(event:)` 都不動）。
- **gRPC 契約**（`proto/PermissionsService.proto`、`Sources/Generated/`）與兩個 aggregate 的 **`openapi.yaml`**——請求／回應形狀與錯誤碼表不變。
- **所有 JS projection**（`projections/`）——D8：`IAM_GetPermissionsProjection.js` 已轉送 `PrivilegeRevoked`，角色事件直接讀角色 stream。
- **`Package.swift`、`IAMContextServer.swift`、`PermissionsService.swift`**——見改動檔案表末段。
- **`PermissionScopeFilter`／`CheckScopeApplicationService`**——department／firm 過濾不動。
- **`GetPermissionsPresenter`／`PermissionsReadModel`**——折疊邏輯不動（`department`／`firm` 仍被使用；`permissions`／`roles` 欄位本 task 後不再被 `getPermissions` 使用，清理屬後續）。`EmployeeAccess.permissions`（aggregate 的直接授權集合）語意不變：仍是「直接授權帳」，不是有效權限；`grantPrivilege`／`revokePrivilege` 的前置條件才把它與重播結果並用。
- **`GetRoleHoldersApplicationService`／`GetRoleHoldersPresenter`／`GetPermissionHoldersPresenter`**——不動（後兩者現只被候選人讀取使用 `coordinator`）。
- **`assignRoles`／`revokeRoles`**——不動（`assignRoles` 仍用 `roleDirectory.resolve` 驗證 roleId 存在）。
- **Middleware `CachingPermissionsProvider` 與所有消費端**——快取行為維持現狀。
- **`docs/tasks/role-permission-composition.md`、`docs/tasks/role-aggregate.md`、`docs/2026-09-21-role-mechanism-plan.html`**——歷史規格與規劃報告保留原文（其中描述舊的聯集語意，已由本 task 取代；registry 以 `depends_on` 表達順序）。`docs/tasks/grantPrivilege.md`、`docs/tasks/revokePrivilege.md` 是 Genesis 產物，不手改。

---

## 驗收標準

### Agent 必做（可機器執行）

前置：KurrentDB 於 `localhost:2113` 運行；四支 projection（`IAM_GetPermissions`、`IAM_PermissionHolders`、`IAM_RoleHolders`、`IAM_GetRoles`）在跑；Step 0 已把基線存到 `/tmp/permission-timeline-baseline/`。

下列腳本在 repo 根目錄執行，**以退出碼判斷**，任何一行印出 `FAIL` 即驗收不過（最後一行印 `ALL PASS` 才算過）。本機 shell 的 `grep`、`diff`、`swift`、`git diff` 被包裝過（會印不實的摘要），所以一律用 `/usr/bin/` 絕對路徑；`grep` 在「無命中」時退出碼是 1，負向檢查因此用 `hasnt`（退出碼必須恰為 1，2＝檔案不存在也算失敗）。

```bash
fail=0
pass()  { echo "PASS  $1"; }
flunk() { echo "FAIL  $1"; fail=1; }
# has／hasnt：固定字串；hasre／hasntre：ERE（不分大小寫）。後面接檔案或目錄。
has()      { local p="$1"; shift; /usr/bin/grep -rqF  -- "$p" "$@"; [ $? -eq 0 ] && pass "has:      $p" || flunk "has:      $p"; }
hasnt()    { local p="$1"; shift; /usr/bin/grep -rqF  -- "$p" "$@"; [ $? -eq 1 ] && pass "hasnt:    $p" || flunk "hasnt:    $p"; }
hasre()    { local p="$1"; shift; /usr/bin/grep -rqiE -- "$p" "$@"; [ $? -eq 0 ] && pass "hasre:    $p" || flunk "hasre:    $p"; }
hasntre()  { local p="$1"; shift; /usr/bin/grep -rqiE -- "$p" "$@"; [ $? -eq 1 ] && pass "hasntre:  $p" || flunk "hasntre:  $p"; }
BASE=/tmp/permission-timeline-baseline

# 1. 編譯 gate
/usr/bin/swift build && /usr/bin/swift build --build-tests && pass "build" || flunk "build"

# 2. 契約符號存在（每項必須命中）
TL=Sources/EmployeeAccessAggregate/Entity/PermissionTimeline/PermissionTimeline.swift
RD=Sources/EmployeeAccessAggregate/Usecase/Port/Out/RoleDirectory.swift
PS=Sources/EmployeeAccessAggregate/Adapter/PermissionTimeline/PermissionTimelineService.swift
RAD=Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift
has "package struct LogPosition" $TL
has "package enum TimelineEvent" $TL
has "package enum PermissionTimelineError" $TL
has "package static func replay(_ entries: [TimelineEntry]) -> Set<String>" $TL
has "func history(ofRoles roleIds: Set<String>) async throws -> [TimelineEntry]" $RD
has "func rolesEverContaining(permission: String) async throws -> Set<String>" $RD
has "protocol EffectivePermissionsReader" Sources/EmployeeAccessAggregate/Usecase/Port/Out/EffectivePermissionsReader.swift
has "struct PermissionTimelineService" $PS
has "func candidateUserIds(permission: String)" $PS
has "heldViaOtherSources" Sources/EmployeeAccessAggregate/Entity/Commands/EmployeeAccess+RevokePrivilege.swift
has "lapsedDirectGrants" Sources/EmployeeAccessAggregate/Entity/Commands/EmployeeAccess+GrantPrivilege.swift
has "effectivePermissionsReader" Sources/EmployeeAccessAggregate/Usecase/Port/In/RevokePrivilege/RevokePrivilegeUsecase.swift
has "effectivePermissionsReader" Sources/EmployeeAccessAggregate/Usecase/Port/In/GrantPrivilege/GrantPrivilegeUsecase.swift
has "PermissionTimelineService(" Sources/EmployeeAccessAggregate/Adapter/GetPermissions/GetPermissionsApplicationService.swift
has "candidateUserIds" Sources/EmployeeAccessAggregate/Adapter/GetPermissionHolders/GetPermissionHoldersApplicationService.swift
has "func history(ofRoles" $RAD
for f in $RAD $PS; do                                          # 兩個讀取點都必須：取原始事件位置、fail-closed 三層
  has "record.position" $f
  has "case let .event(readEvent) = response" $f
  has "PermissionTimelineError.unresolvableEvent" $f
  has "PermissionTimelineError.unmappedEvent" $f
  has "PermissionTimelineError.unhandledEvent" $f
done
has "roleDirectory.resolve" Sources/EmployeeAccessAggregate/Usecase/Port/In/AssignRoles/AssignRolesUsecase.swift   # assignRoles 仍用 resolve

# 3. 負向檢查（每項必須無命中）
hasnt "rolesContaining" Sources Tests                                          # 舊方法（含註解）已移除
hasnt "import RoleAggregate" Sources/EmployeeAccessAggregate                   # 依賴方向：不得反向
hasnt "roleDirectory.resolve" Sources/EmployeeAccessAggregate/Adapter/GetPermissions/GetPermissionsApplicationService.swift   # getPermissions 不再用當下內容
hasnt ".commitPosition" Sources/EmployeeAccessAggregate/Adapter/PermissionTimeline Sources/RoleAggregate/Adapter/RoleDirectory   # 不得用頂層位置排序
hasnt "try response.event" Sources/EmployeeAccessAggregate/Adapter/PermissionTimeline Sources/RoleAggregate/Adapter/RoleDirectory  # 不得走會把「事件無法解析」變成 resourceNotFound 的 accessor
hasnt "readEvent.link" Sources/EmployeeAccessAggregate/Adapter/PermissionTimeline Sources/RoleAggregate/Adapter/RoleDirectory     # 不得用 link 事件的位置
hasntre "purge|tombstone" Sources                                              # P-b 守門：沒有人 purge／tombstone 角色 stream
hasntre "(Grant|Revoke)PrivilegeService\(repository: [A-Za-z]+\)" Sources Tests   # 所有呼叫點都已注入 effectivePermissionsReader

# 4. 回歸保護（起點工作樹在這些路徑沒有未 commit 變更；比對用 /usr/bin/git，git diff 被包裝過）
[ -z "$(/usr/bin/git diff --stat -- proto/ Sources/Generated/ projections/ Package.swift Sources/IAMContextServer/ \
        Sources/EmployeeAccessAggregate/event.yaml Sources/EmployeeAccessAggregate/openapi.yaml Sources/EmployeeAccessAggregate/EmployeeAccessError.swift \
        Sources/RoleAggregate/event.yaml Sources/RoleAggregate/openapi.yaml Sources/RoleAggregate/RoleError.swift)" ] \
  && pass "contracts/wiring diff empty" || flunk "contracts/wiring diff not empty"
# RoleAggregate 內部：起點已有 Role.swift、CreateRoleUsecase.swift 的未 commit 變更（Step 0 已存基線），現在的 diff 必須與基線完全相同。
/usr/bin/git diff -- Sources/RoleAggregate/Entity Sources/RoleAggregate/Usecase | /usr/bin/cmp -s - "$BASE/role-internal.diff" \
  && pass "RoleAggregate internals == baseline" || flunk "RoleAggregate internals changed beyond baseline"
# RoleAggregate 內只有 RoleAggregateDirectory.swift 允許因本 task 而變；docs/integration 只有那一份 html。
[ "$(/usr/bin/git diff --name-only -- Sources/RoleAggregate/Adapter)" = "Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift" ] \
  && pass "RoleAggregate/Adapter only RoleAggregateDirectory" || flunk "RoleAggregate/Adapter diff"
[ "$(/usr/bin/git diff --name-only -- docs/integration)" = "docs/integration/2026-09-24-role-api-update.html" ] \
  && pass "docs/integration only the api-update html" || flunk "docs/integration diff"

# 4b. registry 條目存在且自洽（Step 9）
R=docs/tasks/registry/permission-timeline-composition.json
jq -e '.id == "permission-timeline-composition" and .depends_on == ["role-permission-composition"] and (.status | IN("draft","ready","in-progress","done")) and (.status_history[-1].status == .status)' "$R" > /dev/null \
  && pass "registry entry consistent" || flunk "registry entry"

# 5. 對外文件（Step 8）
H=docs/integration/2026-09-24-role-api-update.html
hasnt "任一來源移除都不影響另一來源" $H
has '<h3><span class="m post">POST</span>/employee-access/{employeeAccessId}/revoke-privilege</h3>' $H
has '<h3><span class="m post">POST</span>/employee-access/{employeeAccessId}/grant-privilege</h3>' $H
has "5 個既有端點" $H
hasnt "3 個既有端點" $H

# 6. projection 仍在跑（非破壞性檢查；不要用 scripts/projection.sh 當檢查，它會刪除重建）
for n in IAM_GetPermissions IAM_PermissionHolders IAM_RoleHolders IAM_GetRoles; do
  curl -sf -u "${KDB_USER}:${KDB_PASS}" "${KDB_URL:-http://localhost:2113}/projections/any" \
    | jq -e --arg n "$n" '.projections[] | select(.name == $n and .status == "Running")' > /dev/null \
    && pass "projection $n Running" || flunk "projection $n"
done

# 7. 測試檔的條數（釘住「新增幾條」，避免漏寫）
[ "$(/usr/bin/grep -c '@Test' Tests/IAMContextTests/PermissionTimelineTests.swift)" -eq 18 ] && pass "18 unit tests" || flunk "unit test count"
[ "$(/usr/bin/grep -c '@Test' Tests/IAMContextTests/RolePermissionCompositionIntegrationTests.swift)" -eq 27 ] && pass "27 composition tests" || flunk "composition test count"

# 8. 測試
for s in PermissionTimelineTests RolePermissionCompositionIntegrationTests RevokePrivilegeIntegrationTests GrantPrivilegeIntegrationTests \
         GetPermissionHoldersIntegrationTests GetPermissionsIntegrationTests DebugFullPermissionsTests ReadSideServiceUnavailableTests \
         AssignRolesIntegrationTests RevokeRolesIntegrationTests RoleIntegrationTests RoleApiHandlerIntegrationTests; do
  /usr/bin/swift test --filter "$s" > /dev/null 2>&1 && pass "test $s" || flunk "test $s"
done
/usr/bin/swift test 2>&1 | tee "$BASE/swift-test-final.log" | /usr/bin/grep -E "Test run with [0-9]+ tests"
/usr/bin/grep -qE "Test run with [0-9]+ tests.* passed" "$BASE/swift-test-final.log" && pass "full suite passed" || flunk "full suite"
b=$(/usr/bin/grep -oE "Test run with [0-9]+ tests" "$BASE/swift-test.log" | /usr/bin/grep -oE "[0-9]+")
n=$(/usr/bin/grep -oE "Test run with [0-9]+ tests" "$BASE/swift-test-final.log" | /usr/bin/grep -oE "[0-9]+")
[ "$n" -eq "$((b + 33))" ] && pass "test count = baseline($b) + 33" || flunk "test count $n != $b + 33"

[ $fail -eq 0 ] && echo "ALL PASS" || { echo "SOME FAIL"; exit 1; }
```

- [ ] 腳本輸出 `ALL PASS`（含 `swift build`／`--build-tests` 綠、契約符號全數命中、負向檢查全數無命中、回歸 diff 與基線相同）
- [ ] `PermissionTimelineTests` 18 條全綠；`RolePermissionCompositionIntegrationTests` 27 條全綠（既有 12 條〔#4 已反轉〕＋新增 15 條）
- [ ] 其餘既有受影響測試檔全綠（證明「換演算法、既有行為不變」）
- [ ] 全套 `swift test` 全綠，總數＝基線＋33

**`PermissionTimelineTests` 的 18 條單元測試**（`Tests/IAMContextTests/PermissionTimelineTests.swift`，純函式、不連 KurrentDB；D3 每條規則各一條，另 7 條專測 D4/D5、排序與邊界）：

| # | 測試 | 對應 |
|---|---|---|
| U1 | `created_event_adds_initial_permissions_and_initial_roles` | D3 建立 profile |
| U2 | `privilege_granted_adds_and_revoked_removes_regardless_of_source` | D3 直接授予／撤銷權限（撤銷不論來源） |
| U3 | `roles_assigned_adds_role_content_as_of_assignment_time` | D3 指派角色、D2 內容為重播到該時間點 |
| U4 | `roles_revoked_keeps_permissions_supplied_by_other_held_roles` | D3 撤銷角色、D4 角色重疊保留 |
| U5 | `role_permission_added_to_held_role_adds_to_effective` | D3 角色新增權限 |
| U6 | `role_permission_removed_from_held_role_keeps_overlap_with_other_role` | D3 角色移除權限、D4 |
| U7 | `role_deleted_behaves_like_role_revoked_and_keeps_overlap` | D3 刪除角色、D4 |
| U8 | `events_of_roles_not_held_only_update_role_content` | D3 未持有的角色只更新內容（含之後被指派時用當時內容） |
| U9 | `direct_grant_is_not_preserved_when_role_that_also_has_it_is_revoked_removed_or_deleted` | D4 直接授權不保留（三條路徑） |
| U10 | `latest_event_wins_after_individual_revoke_direct_grant_reassign_and_role_readd` | D5（直接授予／重新指派／角色再次加入／先收回直接授權後角色才加入，四條路徑；另含 D4 失去後再直接授予回來，§g-2 的引擎面） |
| U11 | `entries_are_ordered_by_commit_then_prepare_not_by_input_order` | D2 排序（含同 commit 不同 prepare） |
| U12 | `simultaneous_revoke_of_overlapping_roles_removes_shared_permission` | D3 撤銷角色（一次撤銷多個彼此重疊的角色） |
| U13 | `deleted_role_content_is_empty_afterwards_and_reassign_or_revoke_is_noop` | 刪除後懸空引用（`[inferred]` I-7） |
| U14 | `unknown_role_contributes_nothing` | 舊字串 roleId／未知角色 |
| U15 | `equal_positions_fall_back_to_input_order_for_synthetic_history` | §a 排序 tie-break（`FakeRoleDirectory` 合成歷史） |
| U16 | `mentioned_role_ids_collects_initial_assigned_and_revoked_roles` | `mentionedRoleIds`：建檔初始角色、`rolesAssigned`、`rolesRevoked` 都收集；其餘事件不貢獻 |
| U17 | `roles_revoked_for_roles_not_held_is_noop` | D3「撤銷角色」的 `Rm = H ∩ Rs`：撤銷沒持有的角色不動 `S`，即使該角色的內容與員工直接授權重疊 |
| U18 | `duplicate_employee_entries_do_not_change_result` | §a link 重複時冪等（員工事件整批重複一次，含 `rolesAssigned`／`rolesRevoked`／`privilegeRevoked`） |

**`RolePermissionCompositionIntegrationTests` 新增與反轉**（沿用該檔既有 helper；新增 helper `revokePrivilege`、`grantPrivilege`；員工事件之後 `waitForProjection()`，角色事件之後不等待）：

| # | 測試 | 涵蓋的驗收條目 |
|---|---|---|
| 4（反轉） | `permission_from_both_direct_grant_and_role_is_lost_when_role_removes_it` | **直接授權與角色重疊**：角色移除該權限後，員工失去它（D4）；HTTP 與 gRPC 兩入口 |
| 13 | `revoke_privilege_on_role_only_permission_succeeds_and_disappears_from_http_and_grpc` | **只來自角色的權限，一次撤銷就在 HTTP 與 gRPC 兩個入口都消失**：角色含 p、q，員工只持有該角色；經 `ApiHandler.revokePrivilege`（驗證 §g 的接線）撤銷 p 回 `.ok` → 兩入口不含 p、仍含 q；aggregate 的直接授權集合仍為空；再撤銷一次 p → `.unprocessableContent`（`permissionNotExist`） |
| 14 | `direct_grant_revoked_then_role_adds_same_permission_grants_it_back` | **先收回直接授權、之後角色才加入同一權限，員工擁有該權限**（D5）：持有空角色 R；直接授予 p → 撤銷 p → 不含 p（等 projection）→ 對 R `addPermissions([p])` → 兩入口含 p（角色事件不等待） |
| 15 | `overlapping_roles_delete_role_keeps_shared_permission` | **角色與角色重疊**的「刪除角色」路徑：A、B 皆含 p，刪除 A 後 p 仍在；再刪除 B 後 p 消失。「撤銷角色」路徑＝既有 #10、「角色移除權限」路徑＝既有 #5（**均須維持綠**，屬同一驗收條目） |
| 16 | `individual_revoke_is_undone_by_reassigning_the_role` | **對個人撤銷後可恢復（D5）**——重新指派角色：撤銷 p → 撤銷角色 R → 再指派 R → 含 p |
| 17 | `individual_revoke_is_undone_when_role_adds_the_permission_again` | 同上——角色再次加入：撤銷 p → 角色 `removePermissions([p])` → 角色 `addPermissions([p])` → 含 p |
| 18 | `individual_revoke_is_undone_by_direct_grant` | 同上——直接授予：撤銷 p（p 只來自角色，直接授權集合不含 p）→ `grantPrivilege([p])`（p ∉ 直接授權，前置條件通過、不重播）→ 含 p |
| 19 | `get_permission_holders_matches_timeline_replay_including_department_filter` | **反查與重播結果一致，含 department 過濾**：U1 只被直接授予、U2 只經角色、U3 只經角色但被個別撤銷、U4 直接授予且角色也有但角色後來移除（D4）、U5 只經角色但屬另一部門；預期 `getPermissionHolders(p)`＝{U1,U2,U5}，帶 department 過濾＝{U1,U2}；且對每位候選人，「在反查結果裡」⇔「`httpPermissions` 含 p」 |
| 20 | `role_edits_and_delete_write_no_employee_events_zero_fanout` | **零扇出**：兩位持有者；對角色依序 `addPermissions`、`removePermissions`、`DeleteRole`；兩入口每一步立即反映，且兩位員工 aggregate 的 `metadata.version` 前後相同（比照既有 #2 的 `streamVersions(of:)`） |
| 21 | `deleted_role_history_is_replayed_and_directory_history_ends_with_roleDeleted` | **已刪除角色的歷史能正確重播**：員工持有 R（p、q）與 S（q）；刪除 R；有效權限＝含 q、不含 p；再對員工 `revokeRoles([R])`（不驗證 roleId）結果不變；`directory.history(ofRoles: [R])` 依位置嚴格遞增、事件順序為 created → added → deleted（P-b） |
| 22 | `revoke_privilege_of_permission_that_is_neither_direct_nor_effective_still_throws_permissionNotExist` | D1 `[inferred]` 的守門：員工持有含 q 的角色；撤銷 `"custom:new"` 與撤銷 q 之外的另一個 catalog 權限 → `permissionNotExist`，且沒有新事件（版本不變） |
| 23 | `initial_permissions_and_roles_in_profile_created_event_are_replayed` | D3 建立 profile：用 `EmployeeAccess(id:userId:department:jobTitle:permissions:roles:status:firm:)` 寫入帶初始權限與初始角色的建檔事件，兩入口的有效權限＝初始權限 ∪ 角色內容 |
| 24 | `resolved_link_record_position_equals_original_stream_position` | **P-a 守門**：用 `KurrentDBClient` 讀 `IAM_GetPermissions-<userId>`（`resolveLinks: true`）與 `IAMEmployeeAccess-<employeeAccessId>`（`resolveLinks: false`），同一事件的 `record.position` 相等，且 `link.position` 大於它 |
| 25 | `grant_privilege_after_role_removes_shared_permission_succeeds_and_returns_it_to_both_entrypoints` | **`grantPrivilege` 與 `revokePrivilege` 對稱（D5 推論，§g-2）**：角色 R 含 p；員工持有 R 並直接授予 p（p ∉ 直接授權，成功）→ 等 projection → 兩入口含 p → R `removePermissions([p])` → 兩入口不含 p（角色事件不等待）且 aggregate 的直接授權集合仍含 p → 經 `ApiHandler.grantPrivilege`（驗證 §g-2 的接線）再授予 p 回 `.ok` → 等 projection → 兩入口都含 p → 再授予 p 一次 → `.unprocessableContent`（`permissionAlreadyExists`：p 現在既在直接授權、又在有效權限） |
| 26 | `non_permission_events_do_not_change_effective_permissions` | **不影響權限的事件型別被明確忽略**（§d 處置總表）：角色 R 含 p、q，員工持有 R 並被個別撤銷 p（有效＝{q}）；依序對角色 `RenameRoleService`、`UpdateRoleDescriptionService`，對員工 `PromoteUserService`、`TransferDepartmentService`；等 projection → 兩入口仍含 q、仍不含 p（改名、改描述、升遷、轉調既不報錯、也不讓被撤銷的 p 復活） |
| 27 | `unmapped_event_in_role_or_employee_stream_fails_closed` | **fail-closed 邊界**（I-5、I-12）：(a) 用 `KurrentDBClient` 對某角色的 `IAMRole-<roleId>` stream 直接 append 一筆 eventType 為 `BogusEvent` 的 JSON 事件 → `directory.history(ofRoles: [roleId])` 拋 `PermissionTimelineError.unmappedEvent`；持有該角色的員工經 `ApiHandler.getPermissions` 回 `.serviceUnavailable`、直接呼叫 `PermissionsService.getPermissions` 得到 `response.accepted == .failure`（code `.aborted`；**不要用**既有 helper `grpcPermissions`，它遇到 failure 會 `Issue.record` 讓測試變紅），不是略過該筆後回一份看似正常的權限；(b) 對員工的 `IAMEmployeeAccess-<employeeAccessId>` 原始 stream append 同樣的事件 → `PermissionTimelineService.effectivePermissions(employeeAccessId:)` 拋 `unmappedEvent`，`ApiHandler.revokePrivilege` 撤銷只來自角色的權限回 `.serviceUnavailable` 且該原始 stream 的事件筆數不變（不寫事件；用 `KurrentDBClient` 讀原始 stream 前後計數，不用 aggregate 的 `metadata.version`——它只反映可解碼的事件）。兩個 stream 都用本測試自建的 id，不污染其他測試 |

### Human 補做（需要人類介入）

- [ ] 啟動 IAMContextServer（需設 `IAM_ADMIN_API_TOKEN`、`IAM_GRPC_AUTH_TOKEN` 兩個環境變數），走 golden path：`POST /roles` 建角色 → `add-permissions` 加兩個 catalog 內權限 p、q → `assign-roles` 指派給測試員工 → `GET /employee-access/permissions/{userId}` 與 gRPC 都含 p、q → `POST /employee-access/{employeeAccessId}/revoke-privilege`（body 的 `permissions` 放 p）回 200 → 等約 1 秒（projection）→ HTTP 與 gRPC 都不含 p、仍含 q。
- [ ] 承上：對該角色 `remove-permissions` p 再 `add-permissions` p → 立即（不等待）再查，p 回來（D5）；或重新指派角色、或直接 `grant-privilege` p，p 回來。
- [ ] D4 手動確認：測試員工同時直接授予 p 並持有含 p 的角色；對角色 `remove-permissions` p → 員工失去 p；再 `grant-privilege` p 回 200（§g-2）→ 等約 1 秒 → 員工又有 p；第二次 `grant-privilege` p 回 422 `permissionAlreadyExists`。
- [ ] `GET /employee-access/permission-holders?permission=p`：被個別撤銷 p 的員工不出現；帶 `department`／`firm` 過濾結果一致。
- [ ] **上線前資料比對**：在有代表性資料的環境，取部署前 `GET /employee-access/permissions/{userId}` 的快照，部署後逐位比對（建議先抽樣 20 位、涵蓋有角色與有直接授權的人）；所有差異都必須能用 D4／D5 解釋（例如「角色曾移除該員工同時直接持有的權限」），無法解釋的差異先停下回報。
- [ ] **上線前 fail-closed 掃描**：部署後對全部員工各查一次 `GET /employee-access/permissions/{userId}`（可沿用既有的員工匯入清單迭代）；出現 HTTP 503 的員工，代表他自己或他持有過的角色的 stream 裡有未登記型別／無法解碼的事件（失敗路徑 fail-closed），要先找出那筆事件並處理，才能放行上線。預期為零筆。
- [ ] **效能量測**：對持有角色最多、事件最多的員工量 `getPermissions` 的延遲（P95）與 `getPermissionHolders` 對高頻權限的延遲；若不可接受再評估快取或快照（本 task 的 Non-goal）。
- [ ] **跨 repo 冒煙測試**（外部 repo，agent 驗收管不到）：以測試資料在 OpportunityContext 本機環境或 mendesky-web 選派人 modal 走一次，確認被個別撤銷權限的人不再出現在候選清單、其他人不受影響。
- [ ] 通知 IAM console 前端負責人：`revoke-privilege` 對角色來源權限改為成功、`grant-privilege` 對「直接授權還在帳上但已失效」的權限改為成功（D7）；文件見 `docs/integration/2026-09-24-role-api-update.html`。

---

## 已知限制

1. **員工側事件經 projection，最終一致**：對個人撤銷／授予、指派角色後，`getPermissions` 要等 `IAM_GetPermissions-<userId>` 連結（數百 ms）才反映；與階段二的直接授權延遲相同。角色編輯仍是強一致、立即反映；因此員工側與角色側新鮮度不同，視窗內的合併結果不保證是單一時間點的快照（失敗路徑「員工側 projection 延遲」有例子；階段二同樣如此）。消費端仍有 60 秒快取（D7，Non-goal）。`revokePrivilege`／`grantPrivilege` 自己的前置檢查讀原始 stream，不受此延遲影響。
2. **`EmployeeAccess.permissions` 是「直接授權帳」，不是有效權限**：D4 之下「直接授予 p 且角色也有 p，之後角色移除 p」→ 員工失去 p，但直接授權帳仍含 p。`grantPrivilege` 的脫鉤已在本 task 處理（§g-2）；殘留的事實是：(a) 此時 `revokePrivilege(p)` 仍會成功（p 在直接授權裡），效果只是清掉帳上的 p；(b) 再授予 p 會對同一權限多寫一筆 `PrivilegeGranted`——重播對重複授予是冪等的，反查候選人讀取已對 `userId` 去重，`GetPermissionsPresenter` 的折疊也去重，所以沒有下游影響。
3. **反查的候選人發現有兩個盲區**：`UserAccessProfileCreated` 事件裡的初始角色與初始權限不會被 `IAM_RoleHoldersProjection.js`（寫入 `IAM_GetRoleHolders-<roleId>`）與 `IAM_PermissionHoldersProjection.js`（寫入 `IAM_GetPermissionHolders-<permission>`）連結（它們只處理 `RolesAssigned`／`RolesRevoked` 與 `PrivilegeGranted`／`PrivilegeRevoked`），所以只靠建檔事件持有權限的員工在 `getPermissionHolders` 裡不會被找到，但 `getPermissions` 是對的。現行建檔路徑一律給空權限、空角色（`EmployeeAccess.swift` 便利 init），只有 2026-06-22 之前的舊資料可能有初始權限；階段二的反查同樣看不到它們，不是新退化。另外三個候選人來源都是最終一致的 projection，剛異動的數百 ms 內反查可能漏人（與階段二同量級）；且候選人階段經 DDDKit `fetchEvents`，解碼失敗的事件只記 warning 並略過（不在 fail-closed 範圍，後果只是少列人，見 §e）。
4. **反查成本**：候選人數 N，每人一次 link stream 讀取，所有候選人共用一次角色歷史讀取（每個相關角色一次 stream 讀取）；讀取為序列。候選人上限是全公司員工數（數百人），與既有 department／firm 過濾迴圈同量級。若日後需要更快，可對員工 stream 讀取改並行，或加快取／快照（另開 task）。
5. **每次 `getPermissions` 都重讀事件**：員工與其角色的事件數隨時間成長，沒有快照。消費端 60 秒快取吸收大部分呼叫；Human 補做要求量測，超標再處理。
6. **行為改變對既有資料的影響（無遷移）**：對「角色曾移除某員工同時直接持有的權限」者，新舊結果不同（新版失去該權限，D4）；「先收回直接授權、後來角色才加入同權限」的人，新版擁有該權限（D5）。這是設計的直接結果，非 bug；上線前以 Human 補做的比對項確認。
7. **P-a 依賴伺服器行為**：「link 的 `record` 帶原始事件位置」只在 KurrentDB 25.1.1.2828 實測確認；整合測試 #24 是升級時的哨兵。
8. **`EmployeeAccessDeleted`（軟刪除員工）不影響時間軸**：`IAM_GetPermissionsProjection.js` 不轉送它，重播把它列為明確忽略，與階段二的 read model 行為一致（軟刪除的員工仍查得到權限；不是新問題）。
9. **`PermissionsReadModel.permissions`／`roles` 折疊成為死欄位**：`getPermissions` 不再使用；保留以免擴大本 task 範圍，後續清理。
10. **既有文件描述舊語意**：`docs/tasks/role-permission-composition.md`（§e、§g）、`docs/tasks/role-aggregate.md`／`.html`、`docs/2026-09-21-role-mechanism-plan.html` 仍寫「直接授權 ∪ 角色展開」；已由本 task 取代，僅 `docs/integration/2026-09-24-role-api-update.html` 在本 task 內更新（D7）。
11. **`[inferred]` 彙整**（理由與替代方案在討論檔「開放問題」）：
    - （以下 I-1 至 I-12 的理由都在討論檔「開放問題」；I-6 已由 I-11 取代）
    - **I-1** D1 放寬後仍檢查「在直接授權或有效權限裡」，都不在才 `permissionNotExist`；直接授權優先、其餘用強一致重播（§g）。
    - **I-2** 查詢路徑讀 link stream、寫入前置檢查讀原始 stream（§e）。
    - **I-3** D6 候選人來源＝三條既有 projection 的 link stream 裡的原始事件，不新增 projection（§e、§h）。
    - **I-4** `rolesContaining` 被 `rolesEverContaining` 取代並移除（§b）。
    - **I-5** 事件解碼失敗、link 無法解析時重播整體失敗（fail-closed），不略過（§c、失敗路徑）。
    - **I-7** `RoleDeleted` 後員工 `H` 仍含該 roleId、角色內容清空（§d）。
    - **P-a 風險** link `record` 位置屬伺服器行為（已實測、有哨兵測試 #24）。
    - **I-8** `FakeRoleDirectory` 的合成歷史放在 `LogPosition(0, 0)`（§j）。
    - **I-9** `PermissionTimelineService` 的員工事件在前、角色事件在後的輸入順序約定（§a）。
    - **I-10** `revokePrivilege` aggregate 以帶預設值的 `heldViaOtherSources` 參數承接 usecase 的重播結果，而不是把前置條件移出 aggregate（§g）。
    - **I-11** `grantPrivilege` 前置條件對齊有效權限（D5 的推論）：`permissionAlreadyExists` 只在「權限既在直接授權、又在有效權限」時回；aggregate 以帶預設值的 `lapsedDirectGrants` 承接 usecase 的強一致重播結果（§g-2）。**讀法**：使用者原話是「在有效權限中，才回 `permissionAlreadyExists`」；本規格解讀為「舊條件（在直接授權）再加上『且在有效權限』」，因為若改成「只要在有效權限就擋」，階段二既有測試 #4 與 D4 情境（先指派含 p 的角色、再直接授予 p）就無法建立。
    - **I-12** fail-closed 邊界收緊：mapper 回 `nil`（未登記型別／非 JSON）、型別既非「處理」也非「明確忽略」、回應不是 `.event`，都整體失敗；不再繼承 DDDKit `fetchEvents` 的靜默略過（P-a、§c、§d 處置總表）。
12. **依賴關係**：`depends_on: ["role-permission-composition"]`。後續（不阻塞本 task）：`getEffectivePermissions` 來源明細、重播快取／快照、`PermissionsReadModel` 死欄位清理、建檔初始角色／權限的反查候選人發現。
13. **前置檢查的角色側不與 `save` 原子化**：`revokePrivilege`／`grantPrivilege` 的重播讀到的角色狀態是讀取當下的快照；員工 stream 有 expected revision 保護，角色 stream 沒有。競態視窗只有「重播完成到 `save` 完成」的毫秒級，後果都是良性且可自癒：多一筆冪等的 `PrivilegeGranted`，或一次可重試的 422（`permissionAlreadyExists`／`permissionNotExist`）。不為此加跨 stream 交易（EventStoreDB 不支援）。
14. **department／firm 過濾沿用既有的 `try?`**：`getPermissionHolders` 帶過濾條件時，讀不到某位持有者的 `GetPermissions` read model（`try? await permissionsPresenter.execute`）會靜默略過該員工。這是階段二既有行為（§h 只換輸入、不改迴圈），後果是少列人、不會多列人；是否改為「只略過 notFound、其餘 503」屬後續（不阻塞本 task）。

## 實作回填（2026-09-30）

| # | 規格原文 | 實作採用 | 理由 |
|---|---|---|---|
| 1 | 整合測試 #19：反查結果與重播結果完全相等 | 只比對測試自己建立的 5 位員工 | p 取自真實權限目錄，本機共用的 KurrentDB 裡還有其他人持有它，完全相等在共用資料庫下不可能成立；比對範圍內的語意與規格意圖相同 |
| 2 | 整合測試 #27：拋出 `PermissionTimelineError` | 拋出 `unmappedEvent(_, "BogusEvent")` | 收緊到規格要求的精確錯誤 |
| 3 | `GetPermissionHoldersApplicationService` 既有註解「並行查」 | 改為「逐一查」 | 註解與實際迴圈不符；迴圈本身未改 |
| 4 | Step 8 未列 | `docs/integration/2026-09-24-role-api-update.html` 的「狀態」行測試數由 103 改為 157 | 說明書對外陳述要與現況一致 |
| 5 | §d「建立 profile」：`H ← H ∪ R₀`、`S ← S ∪ …`（加入） | 改為重設：`H ← R₀`、`S ← P₀ ∪ ⋃ C[r]` | 2026-10-01 部署前對開發環境的唯讀檢查發現：354 位員工的 userId 各有兩筆建檔事件（兩次匯入）。1.4.0 的 GetPermissionsPresenter 對建檔是覆寫 `permissions`，所以舊版只算後一次建檔之後的授權；加入的規則會讓第一次匯入的授權復活，使 411 人中 353 人憑空多出權限。改為重設後與 1.4.0 行為一致，新增單元測試 `second_profile_created_resets_permissions_and_held_roles` |

驗證：`/usr/bin/swift test` 全套 157 個測試、21 個 suite 全綠（基線 124＋新增 33），由主對話在實作完成後獨立重跑確認；本 task 的驗收腳本 66 項 PASS；Gemini 總審 PASS。
