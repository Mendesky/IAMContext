# Genesis dogfood findings — IAMContext

> 來源：在 `IAMContext` 專案實跑 `/bundle-plan → /usecase → /domain-fill → /test-gen → /api → /readmodel-mutation`、再手動補完 GetPermissions read endpoint（`/presenter` + `genesis new` 參考 + `/presenter-fill` 模板）並**實跑 server** 時浮現的工具層問題。
> Genesis 版本：`v0.1.0-phase1k2`（A5/A6 期間 binary 已升級為含 GenesisTODO + verify 的新版）· Bundle：`057e8202-6f1f-4e2c-b821-3b63d931f5df` · 記錄日：2026-06-03 起（A5/A6/read-side 於 2026-06-05 補）
> 範圍：**只記 Genesis 工具/skill 本身的問題**（A = codegen/scaffold bug；B = skill 問題）。專案待辦/業務決策不在此檔。

---

## A. Codegen / scaffold 真實 bug

> 共同性質：**已在本 repo 手動修好，但根因在產生器**（adapter / renderer / plugin / scaffold template），下次 `genesis new` 重生會再長出來。修了治標，要回工具層治本。

### A1 — Aggregate 重複 `id` 宣告（invalid redeclaration）

- **現象**：`EmployeeAccess` 同時有 `package let id: String`（DDDKit AggregateRoot 必需）與 `package var id: String?`（adapter 把 bundle state 的 `id` 欄位也吐成 stored property）→ `Invalid redeclaration of 'id'`，並連帶造成 `Ambiguous use of 'employeeAccessId'`、event 建構 `Missing argument` 等下游編譯錯。
- **檔案**：`Sources/EmployeeAccessAggregate/Entity/EmployeeAccess.swift`
- **本 repo 修法**：移除多餘的 `package var id: String?`（保留 DDDKit 的 `let id: String`）。
- **根因 / 該回哪修**：`swift-adapter.yaml` 的 state 映射把 `id` 也納入。應在 adapter 層把 aggregate identity（`id`）排除出 state stored-field 生成，避免與 DDDKit 必需的 `id` 衝突。
- **建議**：renderer 對 `identityName`/`id` 欄位做去重；或 adapter schema 明確標記 identity 欄位不重複 emit。

### A2 — ReadModel storedField 漏帶 `defaultValue`（init 未初始化所有 stored property）

- **現象**：bundle `readModels[].storedFields` 宣告 `employeeAccessId` 的 `defaultValue: ""`，但生成的 `PermissionsReadModel` 只寫 `package var employeeAccessId: String`（無預設值），導致 `init(userId:)` 出現 `return from initializer without initializing all stored properties`。
- **檔案**：`Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissions/PermissionsReadModel.swift`
- **本 repo 修法**：補回 `package var employeeAccessId: String = ""`。
- **根因 / 該回哪修**：read-model renderer 沒尊重 bundle storedField 的 `defaultValue`。
- **建議**：renderer 對有 `defaultValue` 的 storedField 一律 emit `= <defaultValue>`；或為非 init 參數的 stored property 自動補預設值。

### A3 — Event 建構簽名與 plugin-generated init 不符（`id: UUID()` 多餘參數）

- **現象**：scaffold 自己產的 `EmployeeAccess.swift` full init 與各 command 的 build-event 寫成 `SomeEvent(id: UUID(), employeeAccessId: …, …)`，但 DomainEventGeneratorPlugin 生成的 event init **第一個參數是 `employeeAccessId`，沒有 event 層 `id` 參數** → 全部 event 建構 `Missing argument for parameter 'employeeAccessId'`。
- **檔案**：`EmployeeAccess.swift`（full init）＋ 6 個 `Entity/Commands/EmployeeAccess+<UC>.swift`
- **本 repo 修法**：移除所有 event 建構的 `id: UUID()`（改為 `SomeEvent(employeeAccessId: self.id, …, occurred: .now)`）。
- **根因 / 該回哪修**：scaffold template 產的 event 建構參數列，與 plugin 從 `event.yaml` 生成的 init 簽名不一致（template 假設有 event `id`，plugin 用 `aggregateRootId.alias` 當首參）。
- **建議**：統一 event 建構 template 與 plugin init 契約（以 `event.yaml` 的 `aggregateRootId.alias` 為首參，不 emit `id: UUID()`）。

### A4 —（附帶）SourceKit 即時診斷對 plugin-generated 型別全是假陽性

- **現象**：因 SourceKit **不跑 build plugin**，凡是用到 plugin 生成的 event 型別（建構、欄位）都報 `Missing argument` / `Ambiguous use`，即使 `swift build` 實際編得過。整個 session 反覆誤導，一度把真 bug（A3）誤判成假陽性。
- **性質**：非程式碼 bug，是開發體驗問題。**ground truth 只能靠 `swift build`**（會跑 plugin），不能信編輯器即時 diagnostic。
- **建議**：在 Genesis 文件/skill 註明「plugin-generated 型別的 SourceKit 診斷不可信，以 `swift build` 為準」；或探討讓 plugin 輸出可被 SourceKit 索引的型別 stub。

### A5 — Aggregate category 前綴與 projection/read 前綴不一致（`IAMC` vs `IAM`）→ 靜默斷掉所有 read projection ⚠️最毒

> 2026-06-05 在「補完 GetPermissions read endpoint + 實跑 server」階段發現。

- **現象**：`EmployeeAccess.category` 計算為 `"IAMC\(Self.self)"` = `IAMCEmployeeAccess`（事件寫入 `IAMCEmployeeAccess-<id>`、category 串流 `$ce-IAMCEmployeeAccess`）；但 `IAM_GetPermissionsProjection.js` 訂 `fromStreams(["$ce-IAMEmployeeAccess"])`、presenter `categoryRule = .fromClass(withPrefix: "IAM_")`、server 註解的文件規則是「IAMContext → IAM」。前綴 `IAMC` ≠ `IAM` → 事件落在 `$ce-IAMCEmployeeAccess`、projection 訂 `$ce-IAMEmployeeAccess`（空）→ **read model 永遠收不到事件、永遠空、read endpoint 永遠 404**。
- **最惡毒之處**：**完全不報錯**——編譯過、寫入回 200、projection 部署後 `Running / progress 100%`、查詢只是默默回 404。極難察覺，要追進 KDB 串流（`$ce-IAMCEmployeeAccess` 有事件、`$ce-IAMEmployeeAccess` 空）才看得出來。
- **檔案**：`Sources/EmployeeAccessAggregate/Entity/EmployeeAccess.swift`（`category`）。
- **本 repo 修法**：`"IAMC\(Self.self)"` → `"IAM\(Self.self)"`（對齊 projection + presenter + 文件三方都用的 `IAM`）。
- **根因 / 該回哪修**：aggregate-category renderer 與 read/projection renderer 用了**不同的前綴推導規則**（前者像是取 "IAMContext" 的大寫字母 I-A-M-C → `IAMC`；後者用文件化的 `IAM`）。
- **建議**：把 SourceCategoryPrefix 抽成**單一**來源，aggregate `category`、projection `fromStreams`、presenter `categoryRule` 全部引用它；並在 `genesis verify` 加「aggregate category 前綴 == projection 訂閱前綴」檢查（這種靜默斷鏈最需要自動 gate）。

### A6 — read endpoint 預設 path 與 write path 在 router 撞 param 名 → server 啟動即 fatal

> 2026-06-05 在「實跑 server」時發現。

- **現象**：`/presenter` 的預設 endpoint 模板 `/<kebab-aggregateRef>/{<readModel.key.field>}/<kebab-stripGet(name)>` 對 GetPermissions 產出 `/employee-access/{userId}/permissions`；但 write path 是 `/employee-access/{employeeAccessId}/<action>`。兩者在 Hummingbird router 同一 trie 位置有**不同名的 path param**（`{userId}` vs `{employeeAccessId}`）→ 啟動時 `Fatal error: Route /employee-access/{employeeAccessId} overrides /employee-access/{userId}`，server 直接 crash（編譯/測試都看不出來，只在跑 server 時炸）。
- **觸發條件**：read model 的 key 欄位名（`userId`）≠ aggregate identity 名（`employeeAccessId`），且 read path 把 key 當「位置2 param」、與 write path 同前綴。
- **檔案**：`openapi.yaml` 的 GET path（源於 bundle `presenters[].endpoint.path`）。
- **本 repo 修法**：path 改成位置2 為**固定字**的 `/employee-access/permissions/{userId}`（literal 段與 write 的 param 可共存、不撞）；openapi + bundle presenter 同步。
- **根因 / 該回哪修**：`/presenter` 預設 path 模板把 `key.field` 當位置2 param，未考慮與 aggregate-id-keyed 的 write path 在 router 衝突。
- **建議**：`/presenter` 預設 path 在「key.field ≠ aggregate id 名」時改用 literal 區隔段（如 `/<aggregate>/<resource>/{key}`）或不同 resource 根；並文件化此 router 限制。

---

## B. Skill 問題（重規劃直接相關）

### B1 — `/usecase` doc/scaffold drift（偵測字串對不上）

- **問題**：`/usecase` SKILL.md 的 idempotent 判定說偵測 `fatalError("not implemented")` + `// GENESIS-STUB:` 註解，但實際 scaffold 吐的是 `fatalError("TODO(/usecase skill): pattern is …")`。字串完全不同，只能靠語意硬判「未填」。
- **影響**：idempotent tri-state（未填/已填/半填）判定不可靠；嚴格照 doc 會誤判。
- **建議**：對齊 SKILL.md 偵測字串與 scaffold template 實際 emit 的字串（擇一為準），或改用穩定 marker（如固定註解 tag）而非 fatalError 訊息字串。

### B2 — `/domain-fill` 不處理 `fatalError` 型的洞（漏填 create convenience init）

- **問題**：`/domain-fill` 明文只認 `#error("GENESIS-TODO: …")` 洞；create 的 convenience init 是 `fatalError("GENESIS-TODO: derive non-input payload…")`（fatalError 非 #error），skill v1 跳過。
- **影響**：domain-fill 跑完後，create 的「從 input 推導 permissions/roles/status」洞仍在，且因是 `fatalError` 不擋編譯 → **build 綠但 runtime 會 trap**，容易被誤以為已完成。
- **建議**：把 create convenience-init 的 derivation 洞也納入某個 fill skill 範疇（或統一改成 `#error` 讓它擋 build、被 domain-fill 捕捉）。

### B3 — 跨 skill 斷鏈：新增 domain error code 無法傳到 transport（HTTP 502/503 而非 422）

- **問題**：`/domain-fill` 過程因 bundle precondition（如「permissions not already in user.permissions」）需要 bundle 沒宣告的 error，於是新增了 5 個 domain error case（`permissionAlreadyExists` / `permissionNotExist` / `roleAlreadyExists` / `roleNotExist` / `departmentUnchanged`，改 `EmployeeAccessError.swift` + `errors.md`）。但：
  - **沒有任何 skill 把新 case 同步到 `openapi.yaml` 的 `EmployeeAccessApiError` enum**；
  - `/api` 明文「不寫 openapi.yaml」；
  - 結果這 5 個 domain error 走 HTTP 時，`ApiComponents+EmployeeAccessApiError` 的 mapper 對它們回 `nil` → caller fallback 成 `.undefinedDomainError` → **回 503，而非語意正確的 422**。
- **影響**：domain 層擋掉的合法業務錯誤，在 API 邊界被降級成「未定義錯誤」，contract 與 domain 不一致。
- **根因**：error catalog（domain `<A>Error` + `errors.md`）與 transport error（`openapi.yaml` 的 `<A>ApiError` enum + `ApiComponents` mapper）之間**沒有同步機制**；新增 domain error 是 human/`domain-fill` 動作，但 openapi 端是 codegen 來源，兩者脫節。
- **建議**：補一個「error catalog → openapi ApiError + ApiComponents mapper」的同步流程（可能是 `/api` 擴充、或一個新的 `/error-map` skill、或讓 `errors.md` 成為 openapi ApiError enum 的 SSOT 並由 renderer 生成）。
- **狀態（2026-06-05）**：本 repo 已修——5 個 code 加進 `openapi.yaml` 的 `EmployeeAccessApiError` enum + mapper 各自映射 → 走 **422**（驗證：grant 已存在權限 → 422 `permissionAlreadyExists`、transfer 無變更 → 422 `departmentUnchanged`）。但**根因仍在**（domain↔transport 兩 catalog 無同步機制、`/api` 不寫 openapi），`genesis new` regen 會重現。

### B4 — bundle 流缺「設計/編輯 read model storedFields」的入口（移除 `/readmodel` 後浮現）

- **問題**：原本的 `/readmodel` skill 是 OC 風格（`.ai/contexts/{C}/config.md`、JS projection `projections/OC_Get{R}Projection.js`、`$ce-OC` 串流、`test-review-commit`），與本專案的 bundle 流（`bundle.readModels[]` / `bundle.presenters[]` / Phase 1.k renderer / `genesis new`）**不同血統、目錄結構對不上**（已於 2026-06-03 移除）。
- **移除後缺口**：bundle 流的 read-side 三件套變成 `/presenter`（寫 bundle.presenters[]）+ `/presenter-fill`（填 read AS body）+ `/readmodel-mutation`（填 projector when() body），但 **沒有任何 skill 負責「建立或編輯 read model 的 storedFields」**（即寫 `bundle.readModels[].storedFields`）。
- **影響**：read model 欄位目前只能由初始 bundle 決定；要新增 read model 或調整欄位（例如讓 GetPermissions 也存 roles/jobTitle/department）時，bundle 流沒有對應入口。
- **建議**：補一個 bundle 版的 `/readmodel`（寫 `bundle.readModels[]` + storedFields，與 `/presenter` 同為 bundle-writing skill），與其餘三個 fill/design skill 同血統。

### B5 — `/test-gen` 在 domain 仍為 placeholder 時產出無驗證價值的 test

- **問題**：對 7 個 task spec 跑 `/test-gen`，產出 23 個 scenario：22 個是 `@Test(.disabled)` + `Issue.record` 的 TODO stub（驗證價值 ≈ 0），唯一會跑的 create happy-path 也只是在斷言「placeholder 假資料 == placeholder 假資料」。使用者判定「沒意義」並要求撤除（已撤）。
- **根因**：test-gen 的價值前提是「spec/domain 已定真」。在 domain 還是 placeholder（baseline=[]、allPermissions 假清單、部分 orchestration 當時還是 stub）時產 test，只能得到骨架，得不到驗證。此外 `permissionNotMatch` 類 @error scenario 在 placeholder baseline 下根本觸發不了。
- **建議**：(a) test-gen 加前置檢查/警告：偵測到 domain placeholder（如 baseline 空、fake universe）時提醒「現在產 test 多為 skipped，建議 domain 定真後再跑」；(b) 文件明確區分「scaffold 可跑」與「scenario 已覆蓋」，避免 disabled stub 被誤認為覆蓋。

### B6 —（流程觀察，非 skill bug）跨層選項造成混淆

- **問題**：在執行 `/readmodel-mutation`（mutation 填空層）途中，把「擴充 read model 欄位」（屬 `/readmodel` 設計層）當成 AskUserQuestion 的當下選項提供，混淆了「填空」與「設計」兩個不同層。
- **教訓**：填空層 skill 互動時，欄位/結構層的變更應陳述為「超出本 skill 範疇、需回上游設計 skill」的**事實**，不要列成可即時切換的選項。
- **建議**：在各 fill skill 的互動準則中明確：遇到需要改 type signature / storedFields / bundle 的情況，一律導向上游 design skill，不在當前 skill 內提供跨層選項。

---

## 附：本 repo 已套用的手動修正（供對照，非待辦）

| 項目 | 檔案 | 說明 |
|---|---|---|
| A1 fix | `Entity/EmployeeAccess.swift` | 移除重複 `var id: String?` |
| A2 fix | `Usecase/Projector/GetPermissions/PermissionsReadModel.swift` | `employeeAccessId` 補 `= ""` |
| A3 fix | `EmployeeAccess.swift` + 6 個 `Commands/EmployeeAccess+*.swift` | 移除 event 建構的 `id: UUID()` |
| A5 fix | `Entity/EmployeeAccess.swift` | `category` 前綴 `IAMC` → `IAM`（對齊 projection / presenter）|
| A6 fix | `openapi.yaml` + bundle `presenters[].endpoint.path` | read path → `/employee-access/permissions/{userId}`（避開 router param 撞名）|
| B3 fix | `openapi.yaml`（ApiError enum +5）、`ApiComponents+EmployeeAccessApiError.swift`（5 code 各自映射）、`EmployeeAccessError.swift`/`errors.md` | 5 個業務 error 現正確回 **422**（原 `return nil`→503 已修，2026-06-05 e2e 驗證）|
| read-side | `Adapter/GetPermissions/…ApplicationService.swift`、`EmployeeAccessQueryError.swift`、`ApiHandler.getPermissions`、openapi GET | 手動 splice + `/presenter-fill` 模板補完 GetPermissions read endpoint；projection 部署於 KDB |

> domain-fill 的逐洞意圖紀錄見 `docs/domain-fill-provenance.md`。
