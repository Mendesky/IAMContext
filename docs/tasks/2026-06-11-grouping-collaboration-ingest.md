# I1：GroupingCollaboration 投影儲存 + 三支冪等 gRPC 寫入 API

> ❌ **SUPERSEDED（2026-06-11，user 與夥伴討論定案）**：role→permission 的控管**回到 OC**——使用者對 grouping 的有效權限由 **OC 自己的 read model 吐出**（OC 本地 collaborators × OC 本地 mapping ∩ 既有 gRPC 取得的全域權限），IAM 不再持有共編投影、不需要本 spec 的 aggregate 與三支寫入 API。執法維持兩段 middleware（IAM 全域 + OC 本地）＝ E1/E2 原設計，不受影響。本檔保留作決策紀錄。

> 本檔為**手寫 spec**（非 Genesis 機器產物；Genesis 的 per-UC spec 是同目錄的 `<UC>.md`）。

## 來源

討論：`docs/discussions/2026-06-11-grouping-collaboration-in-iam.md`

## 目標

讓 IAM 持有各 grouping 的協作者角色（**OC 資料的投影**），供後續查詢 API（I2）回答「user 在某 grouping 的有效權限」。資料由 OC 的事件 listener 經三支 gRPC API 餵入（at-least-once 投遞）——因此全部寫入路徑必須**冪等**。IAM 不提供任何人工修改入口：唯一寫入者是 OC listener，SSOT 永遠在 OC。

---

## 介面合約（Interface Contract）

### 1. 新 aggregate：`GroupingCollaboration`（新 module `GroupingCollaborationAggregate`）

- `aggregateRootId` = `quotingCaseGroupingId`；`category` 為 `"IAM\(Self.self)"`（⚠️ 比照 `EmployeeAccess.category` 的修正註解——prefix 必須 `IAM`，勿讓 codegen 慣性產出 `IAMC`）。
- State：`collaborators: [Collaborator]`，其中（IAM 側自己的型別，doc comment 標明是 OC 概念的 ingested 投影）：

```swift
package struct Collaborator: Codable, Sendable, Equatable {
    package let userId: String
    package let role: CollaboratorRole
}
package enum CollaboratorRole: String, Codable, Sendable {   // closed enum，禁 rawValue fallback
    case owner, editor, viewer
}
```

### 2. 事件（event.yaml → DDDKit plugin codegen）

| 事件 | kind | payload |
|---|---|---|
| `GroupingCollaborationCreated` | createdEvent | `userId: String`、`role: CollaboratorRole`（第一位協作者＝OC 建立 grouping 時的 owner 註冊）|
| `CollaboratorRegistered` | domainEvent | `userId`、`role` |
| `CollaboratorRoleChanged` | domainEvent | `userId`、`role`（新值）|
| `CollaboratorRemoved` | domainEvent | `userId` |
| `GroupingCollaborationDeleted` | deletedEvent | （無 payload）⚠️ **DDDKit 硬需求**：`AggregateRoot` 協定要求 `DeletedEventType` associatedtype，generator 只在 event.yaml 含 deletedEvent 時才綁定（鏡像 `EmployeeAccessDeleted` 先例）。**不開放任何 delete 命令/API**，僅補 `when(event:)`（照 `EmployeeAccess+Delete.swift` 的形）滿足協定 |

### 3. 命令（**冪等是硬規格**：已在目標狀態 → 成功 no-op、不發事件、不拋錯）

| 命令 | guard 與行為 |
|---|---|
| `registerCollaborator(userId:role:)` | 同 userId **同 role** 已存在 → no-op；同 userId **不同 role** 已存在 → 視為 changeRole（更新至目標 role，emit `CollaboratorRoleChanged`——listener 重放或順序邊界時的自癒行為）；不存在 → emit `CollaboratorRegistered` |
| `changeCollaboratorRole(userId:role:)` | 不存在 → emit `CollaboratorRegistered`（自癒：漏掉 register 的補登）；存在同 role → no-op；存在不同 role → emit `CollaboratorRoleChanged` |
| `removeCollaborator(userId:)` | 不存在 → no-op；存在 → emit `CollaboratorRemoved` |

> 與 OC 端 aggregate 的差異是刻意的：OC 的命令是 user-facing、有嚴格 guard（duplicate→錯誤、owner 不可動）；**IAM 端是投影 ingest，目標是收斂到 OC 已發生的事實**，所以全部寬鬆冪等、無 owner 特權規則（OC 已把關過）。`apply`/`when` 照 DDDKit 慣例：`when` 才改 state。

### 4. gRPC 服務（新 proto + server actor）

`proto/GroupingCollaborationService.proto`（同 package `IAMContext`；protoc 指令與 `PermissionsService.proto` 同款、輸出進 `Sources/Generated`、`Visibility=Package`）：

```proto
service GroupingCollaborationService {
  rpc RegisterCollaborator (RegisterCollaboratorRequest) returns (CollaborationAck);
  rpc ChangeCollaboratorRole (ChangeCollaboratorRoleRequest) returns (CollaborationAck);
  rpc RemoveCollaborator (RemoveCollaboratorRequest) returns (CollaborationAck);
}
message RegisterCollaboratorRequest { string grouping_id = 1; string user_id = 2; CollaboratorRole role = 3; }
message ChangeCollaboratorRoleRequest { string grouping_id = 1; string user_id = 2; CollaboratorRole role = 3; }
message RemoveCollaboratorRequest { string grouping_id = 1; string user_id = 2; }
message CollaborationAck {}
enum CollaboratorRole { COLLABORATOR_ROLE_UNSPECIFIED = 0; COLLABORATOR_ROLE_OWNER = 1; COLLABORATOR_ROLE_EDITOR = 2; COLLABORATOR_ROLE_VIEWER = 3; }
```

Server actor `GroupingCollaborationService`（`Sources/IAMContextServer/`，鏡像 `PermissionsService.swift`）：
- find-or-create：`repository.find(byId: grouping_id)` 為 nil 且是 Register → 以 designated init 建 aggregate（emit `GroupingCollaborationCreated`）；其餘走對應命令。
- **save 前先檢查**：命令執行後 `aggregate.events` 為空（冪等 no-op）→ **直接回 ack、不呼叫 save**（⚠️ `save` 會無條件 append events——空陣列 append 對 KurrentDB 的行為未驗證，不可依賴）。有新事件才 `repository.save(aggregateRoot:userId: "oc-collaborator-listener")`（系統寫入，operator 記常數、與「被指派的人」區分）。
- ChangeRole/Remove 對**不存在的 grouping**：Change → 建 aggregate 後補登（同命令自癒語意）；Remove → no-op 成功（冪等）。
- 錯誤映射（鏡像 PermissionsService）：`role == UNSPECIFIED` 或空字串參數 → `.invalidArgument`；其他失敗 → `.aborted`。冪等 no-op 一律回成功 ack。
- 註冊進 `GRPCServer(services: [PermissionsService(...), GroupingCollaborationService(...)])`。

---

## 改動檔案

| 檔案路徑 | 改動描述 |
|---|---|
| `Sources/GroupingCollaborationAggregate/`（**新 module**）| 鏡像 `EmployeeAccessAggregate` 的版型：`event.yaml`、`event-generator-config.yaml`（複製後改 aggregate 名）、**`projection-model.yaml`**（⚠️ `ModelGeneratorPlugin` 啟動即 guard 此檔、缺檔直接 throw——I1 無 read model 就放空定義，但檔案必須存在）、`Entity/GroupingCollaboration.swift`、`Entity/Collaborator.swift`、`Entity/Commands/`×3 + Delete 的 `when`、`Usecase/Port/Out/GroupingCollaborationRepository.swift`（10 行 `EventSourcingRepository` struct，照 `EmployeeAccessRepository`）。**本 module 不需要 openapi**（I1 無 HTTP；OpenAPIGenerator plugin 不掛）|
| `proto/GroupingCollaborationService.proto` | **新檔**（§4）|
| `Sources/Generated/GroupingCollaborationService.pb.swift`、`.grpc.swift` | **protoc 產物**（重生指令照 Package.swift 既有註解，加上新 proto 檔；勿手改）|
| `Sources/IAMContextServer/GroupingCollaborationService.swift` | **新檔**：gRPC actor（§4）|
| `Sources/IAMContextServer/IAMContextServer.swift` | `services:` 陣列加第二個 service |
| `Package.swift` | 新 target `GroupingCollaborationAggregate`（deps：DDDKit、IAMContextShared；plugins：DomainEventGeneratorPlugin、ModelGeneratorPlugin）；`IAMContextServer` target deps 加它；test target deps 加它 |
| `Tests/IAMContextTests/`（GroupingCollaboration 命令冪等測試）| **新測試**（整合測試照 `IntegrationTestSupport` 既有 pattern）`[inferred]` |

**受影響但不改**：`EmployeeAccessAggregate`（**零改動**——Genesis scaffold 原封）；`PermissionsService.swift`；OC 端 listener（OC 的 task，另案）。

---

## 實作步驟

### Step 1 — 新 aggregate module
1. 複製 `EmployeeAccessAggregate` 的 `event-generator-config.yaml` 形狀、改名；寫 `event.yaml`（§2 **五**個事件：4 個業務事件 + `GroupingCollaborationDeleted` deletedEvent）；放 `projection-model.yaml`（空定義即可，**檔案必須存在**——ModelGeneratorPlugin 缺檔即 throw）。
2. `GroupingCollaboration.swift`：state + `category`（`"IAM\(Self.self)"`，附 prefix 警告註解）+ designated init（emit `GroupingCollaborationCreated`）+ `init?(first:other:)` replay + `ensureInvariant()`（本 aggregate 無業務不變式——投影 ingest，留空實作並註明理由）。
3. 三個命令檔照 §3 語意；`when(event:)` 各自維護 `collaborators`（Registered→append、RoleChanged→整顆替換、Removed→removeAll by userId；replay 容錯 silently-skip）；另補 Deleted 的 `when`（照 `EmployeeAccess+Delete.swift`，無對外命令）。
4. Repository struct（10 行）。

### Step 2 — proto + codegen
1. 寫 proto；跑 protoc（指令照 Package.swift 註解、`-I proto` 加新檔）；產物落 `Sources/Generated`。

### Step 3 — server actor + wiring
1. `GroupingCollaborationService.swift` 鏡像 `PermissionsService.swift`（actor、init 收 kdbClient、每 RPC 建 repository → find-or-create → 命令 → save）。
2. `IAMContextServer.swift`：services 陣列追加。

### Step 4 — 測試（冪等是重點）
1. register 兩次同 (userId, role) → 第二次成功且 stream 只有一筆 Registered。
2. register 不同 role → 收斂為 RoleChanged。
3. changeRole 對不存在的 userId → 補登（Registered）。
4. remove 不存在 → no-op 成功。
5. replay：四種事件折出正確 collaborators。

---

## 失敗路徑

gRPC handler：參數無效（空 id／UNSPECIFIED role）→ `.invalidArgument`；KDB 失敗等 → `.aborted`（listener 視為可重試，checkpoint 不前進）。**冪等 no-op 一律成功 ack**（listener 重放安全）。命令層不對 ingest 拋業務錯誤（§3 全收斂語意）；`save` 失敗原樣上拋 → `.aborted`。

---

## 不改動的部分

`EmployeeAccessAggregate` 整個 module；`PermissionsService.proto` 與其產物；HTTP 路由（本 task 無 HTTP）。除「改動檔案」表外均不改動。

### Non-goals（行為層）

- 本 task 不包含查詢 API 與 role→permission mapping（I2）
- 本 task 不包含 OC 端 listener（OC 另案）
- 本 task 不提供任何人工/前端修改共編的入口（唯一寫入者＝OC listener）
- 本 task 不做 owner 特權等業務規則（OC 端已把關；IAM 端是收斂投影）

---

## 驗收標準

### Agent 必做（可機器執行）

```bash
swift build
swift test --filter GroupingCollaboration
grep -n "GroupingCollaborationService" Sources/IAMContextServer/IAMContextServer.swift   # 已註冊
grep -n "IAM\\\\(Self.self)" Sources/GroupingCollaborationAggregate/Entity/GroupingCollaboration.swift
grep -n "service GroupingCollaborationService" proto/GroupingCollaborationService.proto
grep -rn "openapi" Sources/GroupingCollaborationAggregate/ && exit 1 || echo "OK：I1 無 HTTP surface"
```

### Human 補做（需要人類介入）

- [ ] `PORT=24202 swift run IAMContextServer` 起服務後，用 grpcurl（或臨時 client）對 24203 打三支 RPC：register owner → register editor → changeRole → remove，每步後驗 KDB stream `IAMGroupingCollaboration-{groupingId}` 的事件序
- [ ] 重送同一 RPC（模擬 listener 重放）→ ack 成功且 stream 無新事件

---

## 已知限制

- IAM 持有的是**投影**：與 OC 正本的一致性取決於 OC listener 的投遞（listener 未上線前本儲存為空——I2 查詢會回空 permissions，屬正確行為）。
- 形狀目前 OC-specific（groupingId）；多 context per-resource 角色的泛化留待真實第二需求出現。
- 依賴關係：無前置 task（可與 OC listener 並行開發，以 proto 為契約）。I2 依賴本 task。
