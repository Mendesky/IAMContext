---
topic: 員工有效權限的備用方案：角色變更時對每位持有者寫事件（fan-out on write）
date: 2026-10-01
participants: [user, Claude]
status: 備用方案，未採用。現行採時間軸重播（docs/tasks/permission-timeline-composition.md）。本檔供日後出問題時拿出來討論。
---

# 備用方案：角色變更時對每位持有者寫事件

> 背景：2026-10-01 檢討「IAM 機制會不會太複雜」。結論是維持時間軸重播（見 `docs/discussions/2026-09-30-permission-timeline-composition.md` 的 D9、D10）。使用者表示可以接受「對每個持有者寫事件」，要求先把這個做法規劃出來備用。

## 一、何時拿出來討論

出現下列任一情況，就值得重新評估：

1. **效能**：上線前或上線後量測發現，`getPermissions`（HTTP 與 gRPC）的延遲隨事件歷史成長到不可接受。
   - 時間軸重播每次查詢都要讀員工 stream 與他持有過的每個角色 stream 的完整歷史。
   - 門檻待定，建議以消費端快取過期後的 p95 延遲為準。
2. **稽核**：需要在每位員工自己的歷史裡，直接看到「因為角色 R 移除了 p，A 失去 p」。現行做法要重播才看得出來。
3. **規則歸屬**：希望 revoke 與 grant 的前置條件完全由 aggregate 自己判斷，不再依賴讀取端算出的有效權限。現行做法用 `heldViaOtherSources` 與 `lapsedDirectGrants` 參數承接。
4. **框架**：不想再繞過 DDDKit 直接讀 KurrentDB。現行做法為了拿到全域位置必須這樣做。

只有第 1 點時，先試第五節的「中間方案：快取」，通常不需要動到這份備用方案。

## 二、語意：完全不變

這份備用方案只換實作，不換規則。對管理者仍是三句話：

- 權限是一個集合，授予或指派角色是加入，移除或撤銷角色是拿掉。
- 角色之間重疊的權限，撤銷其中一個角色時會保留。
- 最後一次操作說了算。

精確規則以現行規格 `docs/tasks/permission-timeline-composition.md` §d 的重播規則表為準，對應討論紀錄的 D3，包括直接授權不保留、角色與角色之間重疊保留。

**驗收的核心標準**：對同一份事件歷史，新做法算出的有效權限必須和時間軸重播完全相同。API 錯誤碼有兩個邊界差異，見第 3.3 節。現行的重播引擎在遷移期間保留下來，當作比對用的參考答案。

## 三、設計

### 3.1 EmployeeAccess 的狀態

| 欄位 | 內容 |
|---|---|
| `permissions` | 有效權限集合。意義由「直接授權」改為「有效權限」 |
| `roleContributions` | 每個持有角色目前貢獻的權限，以及已套用到的角色版本：`[roleId: (version, permissions)]` |

aggregate 擁有這兩樣資訊後，自己就能算差集：

- 撤銷角色或角色移除權限時，只拿掉「其他持有角色都沒有」的權限。
- 直接授予的權限沒有對應的角色貢獻。如果它也在被撤銷、被移除或被刪除的那個角色的貢獻裡，而其他持有角色都沒有它，就會跟著被拿掉，符合「直接授權不保留」。只撤銷不含它的角色時，它不受影響。

### 3.2 事件

| 事件 | 變更 | 內容 |
|---|---|---|
| `PrivilegeGranted` | 不變 | 加入權限 |
| `PrivilegeRevoked` | 不變 | 拿掉權限，不論來源 |
| `RolesAssigned` | 加欄位 | 每個角色的版本與內容，以及實際加入的權限 |
| `RolesRevoked` | 加欄位 | 實際拿掉的權限 |
| `RoleChangeApplied` | 新增 | `roleId`、`roleVersion`、實際加入的權限、實際拿掉的權限。角色新增權限、移除權限、被刪除，三種情況共用這個事件 |

- 新欄位要設計成選填，舊事件讀到時視為空集合。
  - Role aggregate 上線前寫入的 `RolesAssigned`／`RolesRevoked` 裡，roles 是歷史字串，解析不到角色，貢獻本來就是空的。這兩個事件從 2026-06-10 的初始 commit `8ee15f6` 就存在。
  - Role aggregate 上線後、本方案上線前寫入的事件，靠第六節第 3 步的「建立基準」補上。
- 每個事件都記錄「實際的淨變化」。重播時直接套用，不需要再去讀角色，也不會受角色後來的內容影響。

### 3.3 command 與規則

| command | 前置條件 | 產生的淨變化 |
|---|---|---|
| `grantPrivilege(P)` | P 不全都已在有效權限裡 | 加入 P |
| `revokePrivilege(P)` | P 都在有效權限裡 | 拿掉 P |
| `assignRoles(R)` | R 存在、未被持有 | 加入 R 當下的內容，記下 R 的版本 |
| `revokeRoles(R)` | R 被持有 | 拿掉「R 的貢獻，扣掉其他持有角色的貢獻」 |
| `applyRoleChange(R, version, added, removed)` | 持有 R，且 version 比已套用的新 | 加入 added，拿掉「removed 扣掉其他角色的貢獻」，更新 R 的版本與貢獻 |

- 指派角色時，由 usecase 讀出 R 的內容與版本，交給 aggregate。這一步只讀一次，而且是強一致讀取。
- 刪除角色時，`applyRoleChange` 的 removed 等於該角色的全部貢獻。刪除後，員工仍持有該 roleId，但貢獻為空，這與現行規格 I-7 一致。
- `applyRoleChange` 的版本檢查讓它冪等：同一個角色變更送達兩次，第二次會直接略過。
- **與現行 API 回應的差異**。這個模型沒有獨立的「直接授權」集合，所以 grant 和 revoke 的前置條件只能看有效權限。有兩個邊界情況，回傳的錯誤碼會跟現行不同，但兩者算出的有效權限相同：
  - 先指派含 P 的角色、再直接授予 P：現行回 200，這裡回 422 `permissionAlreadyExists`。
  - 撤銷一個已因角色移除而失效的直接授權：現行回 200，這裡回 422 `permissionNotExist`。
  - 要完全對齊現行，aggregate 得另外記一份直接授權集合，只用來判斷前置條件。見第九節第 6 點。

### 3.4 角色變更傳遞程序

1. 用一支背景程序訂閱 `$ce-IAMRole` 的 `RolePermissionsAdded`、`RolePermissionsRemoved`、`RoleDeleted`。
2. 每收到一個角色事件，就查出該角色的所有持有者，對每位持有者發 `applyRoleChange`。持有者來源是既有的 role-holders projection。
3. 每位持有者的 command 各自獨立。某一位失敗時，重試那一位就好，不影響其他人。

IAM 目前沒有任何背景訂閱，這會是第一支。在 `Sources/` 搜 `PersistentSubscription`、`subscribeToStream`、`subscribe(` 都是 0 筆。工作區已有兩處在用 persistent subscription，可以當範本（2026-10-01 查證）：

- `QuotingContext/Sources/QuotingContextServer/main.swift:53,92`
- `OpportunityContext/Sources/OCServer/OCServer.swift:281,356`

訂閱要直接用 KurrentDB client，跟範本一樣。

### 3.5 對帳

傳遞程序是非同步的，可能漏送，所以要有一支對帳作業：

- 定期比對每位員工記錄的角色版本與角色的最新版本。
- 落後的，就補發 `applyRoleChange`，補上缺的版本。
- 對帳本身也只是發同樣的 command，所以同樣冪等，重跑沒有副作用。

### 3.6 讀取端

- `getPermissions`：回到最初的做法，只折疊員工自己那條 stream，直接回 `permissions`。不讀角色、不合併，也不需要全域位置。
- `permission-holders` 反查：回到一般的 projection。把新事件也 link 進「每個權限一條」的持有者 stream 即可，不必再對每個候選人重播。
- 現行的 `Entity/PermissionTimeline/`、`Adapter/PermissionTimeline/`、`EffectivePermissionsReader`，以及 `RoleDirectory` 的角色歷史讀取，都在遷移完成後移除。

## 四、一致性、失敗與競態

| 情境 | 後果 | 對策 |
|---|---|---|
| 角色改權限 | 持有者要等傳遞程序處理完才生效，預估不到一秒（未量測）。現行做法是下一個查詢就生效 | 要接受。消費端本來就有 60 秒快取 |
| 訂閱重複送達 | 同一個變更套用兩次 | `applyRoleChange` 依版本略過舊的 |
| 傳遞程序中途失敗 | 一部分持有者已更新、一部分還沒 | 每位持有者各自重試，對帳會補齊剩下的 |
| A 剛被指派 R，R 緊接著新增 p，傳遞程序查持有者時 projection 還沒反映 A | A 漏掉 p | 指派時記下 R 的版本，對帳時發現落後就補發。也可以讓傳遞程序等到 projection 追上該事件再查持有者 |
| 角色被刪除後才處理先前的變更 | 對已刪除的角色套用舊變更 | 先依版本排序；刪除事件之後的舊版本直接略過 |
| 傳遞程序本身停機 | 角色變更一直沒生效 | 監控訂閱落後量並告警；恢復後依 checkpoint 接續處理 |
| 某個角色事件一直處理失敗（毒事件） | 無限重試會卡住後面的事件 | 尚未設計。候選做法是重試上限加死信，並告警由人工處理。見第九節第 4 點 |

## 五、中間方案：快取（效能問題時先試這個）

保留時間軸重播，只把結果快取起來：

- 快取的 key 是「員工 stream 的最新位置，加上他持有過的每個角色 stream 的最新位置」。
- 每次查詢先讀這幾條 stream 的最後一筆事件位置，每條只讀一筆。位置都沒變就直接回快取，任一個變了才重播。
- 語意與一致性完全不變，也不需要背景程序。
- 代價是快取要有失效與容量上限，而且多一層要測試的程式。

## 六、從現行做法遷移

1. **雙軌期前置**：先讓現行重播明確忽略 `RoleChangeApplied`，並能讀取 `RolesAssigned`／`RolesRevoked` 的新欄位。現行重播對未列名的事件型別一律 fail-closed（`PermissionTimelineService.swift` 的 `unhandledEvent`，見規格 I-12）。不先處理，新事件一寫入，該員工的查詢就會回 503。
2. **雙軌期**：新事件與 `applyRoleChange` 上線，但查詢仍走時間軸重播。同時對每位員工比對新舊兩種結果，任何差異都要能解釋，否則不能切換。
3. **建立基準**：對每位現有員工發一個「建立基準」command，把時間軸重播算出的有效權限與角色貢獻寫成起點事件。之後的變更都在這個基準上累加。
4. **切換查詢**：`getPermissions` 與反查改讀新的 read model。時間軸重播保留一段時間，當作稽核用的比對工具。
5. **收尾**：確認比對結果連續一段時間沒有差異後，移除時間軸相關程式碼與角色歷史讀取。

截至 2026-10-01，角色功能只在分支 `feat/role-aggregate`，尚未併入 main。`git branch --contains 77d7813` 只列出這條分支。共用開發環境跑的是 `iam-context:1.4.0`，見 `Deployment/DevCommon.yaml`。如果在角色功能上線前就決定改用這個方案，第 1 到 3 步可以省略，直接實作。

## 七、改動範圍估計

| 範圍 | 內容 |
|---|---|
| `Sources/EmployeeAccessAggregate/` | `event.yaml` 新增與擴充事件；aggregate 狀態與 command；GetPermissions presenter 改回單一 stream 折疊 |
| `Sources/RoleAggregate/` | 讓 usecase 能讀到角色版本（DDDKit aggregate 的版本號） |
| `Sources/IAMContextServer/` | 傳遞程序與對帳作業的啟動與組裝 |
| `projections/` | `IAM_GetPermissionsProjection.js` 是事件型別白名單，要加入 `RoleChangeApplied` 並重新部署，否則 read model 讀不到它。持有者 projection 也要 link 新事件，`GetPermissionHolders` 的 presenter 要跟著改 |
| `Tests/` | 第八節的測試；既有的時間軸測試在雙軌期保留，作為比對 |
| 部署 | 背景訂閱的建立、監控與告警 |

## 八、驗收要點

- **等價**：同一份事件歷史，新做法與時間軸重播的有效權限完全相同。測試要包含現行規格的所有重播情境。
- **冪等**：同一個角色變更送達兩次，結果不變。
- **競態**：「剛指派就遇到角色變更」的情境，在對帳後正確。
- **失敗**：傳遞程序在處理到一半時停止，重啟後所有持有者都正確。
- **零查詢成本成長**：持有角色的歷史再長，`getPermissions` 也只讀員工自己那條 stream。

## 九、待討論

1. 角色變更的生效延遲上限要訂多少。這會決定是否需要「等 projection 追上再查持有者」。
2. 對帳的頻率，以及要定期跑還是事件觸發。
3. 傳遞程序放在 IAMContextServer 同一個程序裡，還是獨立部署。
4. 一直處理失敗的事件要怎麼辦：是否需要死信佇列與人工介入流程。
5. 效能的觸發門檻：以什麼指標、什麼數字，判斷要從現行做法換過來。
6. grant 和 revoke 的錯誤碼要不要與現行完全一致。若要一致，就另記一份直接授權集合；若接受第 3.3 節列的兩個差異，要事先通知 console。

## 十、三種做法比較

| | 現行：時間軸重播 | 中間方案：快取 | 備用方案：對每位持有者寫事件 |
|---|---|---|---|
| 查詢成本 | 隨事件歷史成長 | 未變更時只讀幾筆位置 | 只讀員工自己一條 stream |
| 角色變更生效 | 下一個查詢 | 下一個查詢 | 背景程序處理後，預估不到一秒（未量測） |
| 背景程序 | 無 | 無 | 傳遞與對帳各一支 |
| 競態 | 只有良性的前置檢查競態（規格已知限制 #13） | 同現行 | 有，靠版本與對帳處理 |
| 稽核可讀性 | 要重播才看得出原因 | 同現行 | 員工 stream 直接記錄原因 |
| 規則把關 | aggregate 加上讀取端的重播結果 | 同現行 | aggregate 自己 |
| 繞過 DDDKit | 是，為了全域位置 | 是 | 查詢端否；傳遞程序的訂閱要直接用 KurrentDB client |

## 附錄：2026-10-01 Gemini 獨立評估摘要

這次檢討時，經 agy 請 Gemini 在不知道 Claude 看法的情況下獨立評估。原文未落檔，以下為摘要與後續修正。

- **它指出的複雜度來源**：查詢時重播完整歷史、繞過 DDDKit 取全域位置、fail-closed 帶來的維運風險、「最新的事件說了算」不易解釋。
- **它推薦的方向**：明確排除清單，也就是「來源分開＋排除清單」。
- **後續修正**：
  - 它建議沿用 `PrivilegeRevoked` 來記排除，會讓歷史的收回事件溯及既往地變成排除。
  - 使用者隨後確認「直接授權不保留」，而且模型裡沒有「排除」概念。所以這個方向不適用，見時間軸討論紀錄的 D9。
  - 它說現行做法「效能極差」言過其實，以目前規模還跑得動，只是成本會隨歷史線性成長。
  - 它提的第二個替代方案「以時間戳覆寫」，自稱與現行語意無差異，但沒有處理「直接授權不保留」，不成立。
