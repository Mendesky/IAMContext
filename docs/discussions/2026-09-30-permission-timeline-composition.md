---
topic: 員工有效權限改為時間軸重播（可對個人移除來自角色的權限）
date: 2026-09-30
participants: [user, Claude]
status: 決策已鎖定（D1–D8 皆經使用者於 2026-09-30 對話中逐條確認；D9、D10 為 2026-10-01 實作後的架構檢討結論；實作前提 P-a／P-b／P-c 已查證；其餘取捨標 [inferred]，見文末）
---

# 員工有效權限時間軸重播 討論摘要

> 本檔為 session 內討論的落檔摘要（無獨立多方討論輪次），作為 `docs/tasks/permission-timeline-composition.md` 的來源。
> 前置：`docs/tasks/role-permission-composition.md`（階段二，已實作）——本 task 取代它的合成語意（§e、§g 與 `rolesContaining`），不取代其他部分。

## 議題定義

### 目標

階段二的有效權限是「查詢時把直接授權與角色**當下**內容做聯集」。這個模型有一個做不到的需求：
**對單一員工移除某個權限，即使該權限來自角色。** 聯集模型裡，權限只要還在某個角色裡就會被聯集補回來，個人層級的撤銷沒有地方記錄「這個人被拿掉這一項」。

使用者要求改成**依時間順序重播**：把該員工的事件與他持有過的每個角色的事件放進同一條時間軸，依 KurrentDB 全域位置排序，
逐事件更新有效權限集合。這樣「對個人撤銷」就是時間軸上的一個普通事件，之後發生的事件（重新授予、重新指派角色、角色再次加入）自然把權限給回來。

### 範圍

**討論內**：
- 有效權限（`getPermissions`，HTTP 與 gRPC 兩個入口）的計算方式改為時間軸重播。
- `revokePrivilege` 前置條件放寬到可撤銷角色來源的權限。
- `grantPrivilege` 前置條件與其對稱：`permissionAlreadyExists` 改看有效權限（D5 的推論，見 I-11）。
- `getPermissionHolders` 反查改用同一套重播。
- 對外文件（`docs/integration/2026-09-24-role-api-update.html`）反映行為變化。

**討論外（明確排除）**：
- 新增專用的「排除」事件或排除清單（D1 沿用 `PrivilegeRevoked`）。
- 權限來源明細查詢（`getEffectivePermissions`：直接授權 vs 經由哪個角色）。放後續階段。
- 消費端快取失效（Middleware `CachingPermissionsProvider` 60 秒 TTL 維持現狀）。
- 歷史資料遷移（重播直接吃既有事件，不需要寫回任何資料）。
- gRPC proto、HTTP schema、JS projection 的任何變更。

### 約束

- DDDKit 0.x（`Package.resolved` 鎖定 0.3.0，不得升 1.x）；KurrentDB client 2.0.3；本機 KurrentDB 25.1.1.2828。
- `EmployeeAccessAggregate` target 不得依賴 `RoleAggregate` target（`Package.swift` 已是 RoleAggregate → EmployeeAccessAggregate 單向）。
- 跨 aggregate 排序必須用 KurrentDB 全域位置，不能用事件內的 `occurred`（各 writer 的本機時鐘）。

## 決策紀錄

| # | 決策 | 理由（一句） | 狀態 |
|---|---|---|---|
| D1 | 對個人移除權限沿用既有 `revokePrivilege` command 與 `PrivilegeRevoked` 事件，不新增事件。寫入端放寬前置條件：要撤銷的權限不必在該員工的直接授權裡（是否改為「必須在有效權限中」見 I-1） | `PrivilegeRevoked` 的語意本來就是「這個權限被撤銷」、與來源無關，重播時看到它就移除；既有事件 schema 與 projection 一行都不用動 | agreed |
| D2 | 有效權限＝查詢時重播一條合併後的時間軸：該員工 EmployeeAccess 的事件，加上他持有過的每個角色的全部事件（從角色建立開始），依 KurrentDB 全域位置排序；每個角色的內容一律用重播到該時間點的內容，不用角色現在的內容 | 只有把兩邊事件放在同一條時間軸上，才回答得了「這次撤銷發生在角色加入該權限之前還是之後」 | agreed |
| D3 | 重播規則（S＝有效權限集合；「其他角色」＝該時間點仍持有的其他角色，用當時的內容）：建立 profile 重設起點為初始權限與初始角色（2026-10-01 由「加入」更正為「重設」，見規格實作回填 #5）；直接授予 P 加入 P；撤銷權限 P 移除 P（不論來源）；指派角色 R 加入 R 的全部權限；撤銷角色 R 移除「R 的權限扣掉其他角色也有的」；角色 R 新增權限 P（員工持有 R）加入 P；角色 R 移除權限 P（員工持有 R）移除「P 扣掉其他角色也有的」；刪除角色 R（員工持有 R）同撤銷角色 R；員工沒持有的角色發生事件只更新該角色的內容、不動 S | 每個事件對 S 的影響都是一條可逐條對照的集合運算，實作與測試不必靠詮釋 | agreed |
| D4 | 角色與角色之間的重疊權限要保留（D3 的差集）。直接授權不保留：若它也在某個角色裡，該角色被撤銷、移除該權限或刪除時，它會跟著消失 | 兩個角色是兩個獨立來源，撤掉一個不該影響另一個；時間軸不記錄來源，也就不需要新增來源標記這個新狀態 | agreed |
| D5 | 最新的事件說了算。對個人的移除不是永久的：之後直接授予、重新指派角色、角色再次加入該權限，都會把它給回來 | 對個人撤銷是時間軸上的一個點、不是永久黑名單；要做永久排除就得新增排除清單，那是 Non-goal | agreed |
| D6 | `GET /employee-access/permission-holders` 反查用同一套重播規則。候選人＝曾被直接授予該權限的人 ∪ 曾持有「任何時候含過該權限的角色」的人；對每個候選人重播，再套用既有的 department／firm 過濾 | 反查若仍用舊的「當下內容聯集」，會與 `getPermissions` 不一致（有權限卻選不到人，或選得到卻沒權限）；候選人取「曾…」的超集合，是因為重播才是真相，候選只負責縮小要重播的人數 | agreed |
| D7 | 對外契約：gRPC proto 不變、HTTP 形狀不變。行為變化寫進 `docs/integration/2026-09-24-role-api-update.html`：更新「同一個權限同時來自直接授權與角色時，任一來源移除都不影響另一來源」那句，並記錄 `revoke-privilege` 對只來自角色的權限改為成功。消費端 60 秒快取維持現狀 | 消費端不用改碼，但 console 團隊必須知道兩件行為變化，否則會拿舊說明寫前端 | agreed |
| D8 | 不需要改 JS projection：`projections/IAM_GetPermissionsProjection.js` 已經轉送 `PrivilegeRevoked`；角色事件在查詢時直接從角色 stream 讀取 | 員工側事件已在 `IAM_GetPermissions-<userId>` link stream 裡、角色側直接讀原始 stream，兩邊都不需要新的 projection，也就不需要重新部署 | agreed |

## 實作前提查證（file:line 與實測證據見 spec「實作前提查證」一節）

| # | 前提 | 結論 |
|---|---|---|
| P-a | 讀取 KurrentDB 事件時拿不拿得到全域位置，以便排序合併 | **拿得到，但 DDDKit 的 coordinator 把它丟掉了**。`RecordedEvent.position`（commit/prepare）在 client 有；透過 link stream 讀取時要取 `record`（解析後的原始事件）的位置，不是 `link` 也不是 `ReadEvent.commitPosition`（後兩者是 link 事件自己的位置，晚於原始事件）。本機 KurrentDB 25.1.1 以 grpcurl 實測確認。必須直接用 `KurrentDBClient` 讀，不能用 `KurrentStorageCoordinator.fetchEvents` |
| P-b | 角色刪除是 soft delete（寫入 RoleDeleted）還是 tombstone／硬刪除；刪除後原始事件還讀不讀得到 | **寫入 `RoleDeleted` 事件（append-only）**；刪除後 `IAMRole-<roleId>` stream 的全部原始事件仍可讀（本機已刪除角色實測讀到 5 筆事件）。因此「已刪除角色的歷史」能完整重播。唯一會讓 stream 消失的路徑是 `repository.purge`，全 repo 無呼叫者 |
| P-c | 合併重播的程式放哪裡，才不讓 EmployeeAccessAggregate 依賴 RoleAggregate | **擴充既有 `RoleDirectory` port**（新增 `history(ofRoles:)` 與 `rolesEverContaining(permission:)`），重播引擎與員工側讀取放 EmployeeAccessAggregate，角色事件解碼留在 RoleAggregate 的 adapter。取捨見 spec |

## 開放問題／起草者推定（[inferred]，不需使用者當場回答，審查時確認即可）

1. **I-1（D1 的放寬方式）**：放寬後仍要檢查——權限須在「直接授權」或「有效權限」裡，否則維持 `permissionNotExist`。依據：使用者建議「檢查，否則維持回 permissionNotExist」。實作上直接授權優先（不需要重播、與既有行為與時序完全相同），剩下的才用**強一致**重播（讀員工原始 stream，不經 projection）判斷，避免「剛授予、立刻撤銷」被 projection 延遲誤擋。**連帶結果**：既有測試 `revoke_missing_privilege_throws` 的斷言不反轉（"custom:new" 既非直接授權也不在有效權限，仍是 `permissionNotExist`）；若使用者改裁決為「完全不檢查」，該測試才需反轉。
2. **I-2（員工事件的讀取來源）**：查詢路徑讀 `IAM_GetPermissions-<userId>` link stream（既有 projection、最終一致，與現況延遲相同）；寫入前置檢查讀原始 stream `IAMEmployeeAccess-<employeeAccessId>`（強一致）。角色事件兩條路徑都直接讀原始 stream。理由：查詢入口只有 `userId`，沒有 `employeeAccessId`，userId → 員工 stream 的唯一索引就是這個 link stream（且使用者指定用 link stream 並取原始事件位置）；寫入前置檢查手上有 `employeeAccessId`，改讀原始 stream 才不會因 projection 延遲誤擋「剛授予、立刻撤銷」。
3. **I-3（D6 候選人來源）**：「曾被直接授予」讀 `IAM_GetPermissionHolders-<permission>` 的 `PrivilegeGranted` 事件（不看撤銷）；「曾含過該權限的角色」讀 `IAM_GetRoles-all` 的 `RolePermissionsAdded` 事件；「曾持有該角色」讀 `IAM_GetRoleHolders-<roleId>` 的 `RolesAssigned` 事件。三者都是既有 projection 的 link stream，不新增 projection。代價：建檔事件裡的初始角色／初始權限不會被這三條 link 到，反查看不到（已知限制）。
4. **I-4（舊 port 方法）**：`rolesContaining(permission:)`（只回「目前」含此權限的角色）被 `rolesEverContaining(permission:)` 取代並移除，避免兩個語意相近的方法並存。
5. **I-5（解碼失敗）**：時間軸讀取遇到無法解碼的事件時整體失敗（503／gRPC aborted），不像 DDDKit `fetchEvents` 那樣略過。理由：略過一筆撤銷事件會讓已被撤銷的權限復活，權限系統應 fail-closed。
6. **I-6（D4 帶來的副作用；已由 I-11 取代）**：D4 之下，「直接授權 P 且角色也有 P，之後角色移除 P」會讓員工失去 P，但 `EmployeeAccess.permissions`（直接授權集合）仍含 P，此時 `grantPrivilege(P)` 會被 `permissionAlreadyExists` 擋下。原本記為「另一個 task、本 task 不動」，2026-09-30 依使用者指示改為納入本 task，見 I-11。
7. **I-7（角色刪除後的 held 狀態）**：重播時 `RoleDeleted` 之後員工的 held 集合仍含該 roleId（員工事件沒有變），但該角色的內容清為空集合；之後對該 roleId 的撤銷／再指派都不影響 S。與階段二「解析不到 = 零權限貢獻」一致。
8. **I-8（測試替身的位置）**：`FakeRoleDirectory` 由 `resolved` 合成歷史時，事件位置固定為 `LogPosition(commit: 0, prepare: 0)`。理由：真實事件位置一律大於 0，合成的角色歷史因此永遠早於任何真實員工事件，維持階段二「角色內容在指派當下已存在」的測試語意，且不必讓測試去偽造 log 位置。
9. **I-9（輸入順序約定）**：`PermissionTimelineService` 併入時間軸時固定「員工事件在前、角色事件在後」。理由：真實位置唯一，順序不影響結果；只有合成歷史（位置相同）會用到輸入順序當 tie-break，此約定讓結果可重現。
10. **I-10（aggregate 承接方式）**：`revokePrivilege` 以帶預設值的 `heldViaOtherSources` 參數承接 usecase 的重播結果，前置條件仍留在 aggregate，而不是移到 usecase。理由：與 `grantPrivilege` 同一風格、舊呼叫端不用改、aggregate 不依賴任何 port；替代方案（前置條件整個移到 usecase，比照 Role 的驗證放 usecase）也可行，審查時二選一即可。
11. **I-11（`grantPrivilege` 前置條件對齊有效權限；D5 的推論）**：D5 明定「之後直接授予……都會把它給回來」，但 D4 之下（直接授予 P 且角色也有 P，之後角色移除 P），`EmployeeAccess.permissions`（直接授權集合）仍含 P，`grantPrivilege(P)` 會被 aggregate 前置條件擋成 `permissionAlreadyExists`，直接授予因此無法把 P 給回來，違反 D5。修法比照 I-1／I-10：usecase 在「請求的權限有已在直接授權者」時，以強一致重播（讀員工與角色原始 stream）判斷，再以帶預設值的 `lapsedDirectGrants` 參數交給 aggregate；`permissionAlreadyExists` 只在「既在直接授權、又在有效權限」時回。P 不在直接授權（含只來自角色的 P）維持成功、不重播——階段二既有測試 #4 依賴此行為。**取代 I-6**。替代方案：「只要在有效權限就擋」會讓「先指派含 P 的角色、再直接授予 P」無法建立 D4 情境（測試 #4 即是），不採用；審查時二選一即可。
12. **I-12（fail-closed 邊界收緊；audit-spec 2026-09-30 發現）**：I-5 原本只涵蓋「解碼拋錯」。查證 DDDKit 與 client 原始碼後發現三個會靜默丟事件的縫隙：(a) 生成的 `EventTypeMapper.mapping` 對未登記型別／非 JSON 回 `nil`，原設計的 `guard let … else { continue }` 會略過；(b) `Streams.ReadResponse.event` 把「事件無法解析」丟成與「stream 不存在」同一個 `resourceNotFound`，原設計的 `catch KurrentError.resourceNotFound` 會把它當成 stream 不存在而丟掉整段；(c) `switch` 的 `default: continue` 會吞掉日後新增的事件型別。改為：非 `.event` 回應、mapper 回 `nil`、型別既非「處理」也非「明確忽略」都拋 `PermissionTimelineError`，整體 503／gRPC aborted。副作用：員工或角色 stream 裡混進未登記型別的事件時，`getPermissions` 由靜默略過變成 503——上線前以 Human 補做的 fail-closed 掃描確認現有資料沒有這類事件。候選人階段（經 DDDKit `fetchEvents`）不在此範圍，後果只是少列人。

## 後續決策（2026-10-01，實作完成後的架構檢討）

實作完成後，使用者問「這套 IAM 機制會不會太複雜」，要求規劃更好的做法。檢討經過與結論：

- **D9 維持時間軸重播，不改為「來源分開＋排除清單」。** 檢討時曾提出改為：有效權限＝（直接授權 ∪ 持有角色的現有權限）− 排除清單，Gemini 的獨立評估也推薦這個方向，摘要見備用方案文件的附錄。使用者在 2026-10-01 的對話中確認兩件事後，這個方案不適用：
  - 直接授予的權限不保留，會隨角色的移除一起被移除。這要看「直接授予」與「角色移除」誰先發生，只看當下狀態的設計表達不了。
  - 使用者的模型裡只有授予與移除，沒有「排除」這個概念。被移除過的事實記在事件的先後順序裡，時間軸重播本身就表達了這件事。
  - 結論：使用者的語意與現行實作一致，複雜的是實作，不是規則。對管理者，規則可以用三句話說明：權限是一個集合，授予或指派角色是加入，移除或撤銷角色是拿掉；角色之間重疊的權限，撤銷其中一個角色時會保留；最後一次操作說了算。
- **D10 「對每個持有者寫事件」列為備用方案。** 使用者表示可以接受對每個持有者寫事件，因此評估了這個做法。評估結論：讀取端與規則把關會簡化。對外語意不變，只有兩個錯誤碼的邊界差異。但複雜度會轉到角色變更的非同步傳遞，包括冪等、競態、對帳，以及 IAM 第一支背景訂閱。以目前規模不划算。完整規劃與重新評估的觸發條件見 `docs/discussions/2026-10-01-permission-fanout-backup-plan.md`。
