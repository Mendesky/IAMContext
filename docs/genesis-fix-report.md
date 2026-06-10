# Genesis 修正文件（IAMContext dogfood）

> **目的**：彙整在 `IAMContext` 專案實跑 Genesis 全流程（`bundle-parse → new → /usecase → /domain-fill → /test-gen → /api → /presenter → /presenter-fill → /readmodel-mutation`，再實跑 server + 部署 projection）時遇到的**工具層問題**，給 Genesis 維護者修正。
> **範圍**：只列 Genesis（codegen / renderer / plugin / adapter / skill / CLI）該修的問題。本專案的業務決策（權限方案、baseline 內容、是否要 resign event…）**不在此文件**。
> **環境**：bundle `057e8202-6f1f-4e2c-b821-3b63d931f5df`；專案以 `v0.1.0-phase1k2` 生成（fatalError-hole 世代），dogfood 後期 binary 已升級為含 `GenesisTODO` + `genesis verify` 的新版（G8 相關）。
> 每條皆「已在本 repo 手動修/繞過 → 但根因在工具，`genesis new` 重生會重現」。詳細修法見 `docs/genesis-dogfood-findings.md`；domain-fill 逐洞紀錄見 `docs/domain-fill-provenance.md`。

**嚴重度**：P0 = 靜默錯誤（不報錯、結果錯，最危險）｜P1 = 直接壞（編不過 / server crash，明顯）｜P2 = 語意錯 / 工作流缺口｜P3 = drift / 體驗。

---

## 1. Codegen / renderer / adapter bug

### G1 — [P0] Aggregate category 前綴與 projection/presenter 不一致 → 靜默斷掉所有 read projection
- **症狀**：read endpoint 永遠回 404、read model 永遠空，但**全程不報錯**（編譯過、寫入 200、projection 部署後 `Running / progress 100%`）。
- **元件**：aggregate renderer（`<A>.category`） vs read/projection renderer（projection JS `fromStreams`、presenter `categoryRule`）。
- **根因**：兩個 renderer 用**不同的前綴推導規則**。aggregate 產 `"IAMC\(Self.self)"`（疑似取 "IAMContext" 大寫字母 I-A-M-C）→ 事件寫到 `$ce-IAMCEmployeeAccess`；projection/presenter/文件用 `"IAM"`（IAMContext → IAM）→ 訂 `$ce-IAMEmployeeAccess`（空）。前綴差一個 `C`，事件永遠流不到 projector。
- **重現**：`genesis new` 任一含 read model 的 context → 比對 `<A>.category` 字串前綴 vs `projections/*.js` 的 `fromStreams(["$ce-<prefix><A>"])` 前綴 → 不一致。
- **建議修法**：把 SourceCategoryPrefix 抽成**單一來源**（一個函式/設定），aggregate `category`、projection `fromStreams`、presenter `categoryRule` 全部引用它。
- **驗收**：(a) 生成後三處前綴字串相同；(b) `genesis verify` 新增檢查「aggregate category 前綴 == projection 訂閱前綴」（這種靜默斷鏈最需要自動 gate）。

### G2 — [P1] Aggregate 重複 `id` 宣告（invalid redeclaration）
- **症狀**：`Invalid redeclaration of 'id'`，連帶 `Ambiguous use of '<aggId>'`、event 建構 `Missing argument`。編不過。
- **元件**：aggregate renderer + `swift-adapter.yaml` state 映射。
- **根因**：adapter 把 bundle `state[]` 的 `id` 欄位也吐成 stored property（`var id: String?`），與 DDDKit `AggregateRoot` 必需的 `let id: String` 衝突。
- **建議修法**：把 aggregate identity（`id` / `identityName`）排除出 state stored-field 生成。
- **驗收**：生成的 aggregate 直接編譯通過、只有一個 `id` 宣告。

### G3 — [P1] ReadModel storedField 漏帶 `defaultValue` → init 未初始化所有 stored property
- **症狀**：`return from initializer without initializing all stored properties`。編不過。
- **元件**：read-model renderer。
- **根因**：bundle `readModels[].storedFields[].defaultValue`（如 `""`）沒被 renderer 採用，生成 `var <f>: String`（無預設值），但 init 沒設它。
- **建議修法**：有 `defaultValue` 的 storedField 一律 emit `= <defaultValue>`；或對非 init 參數的 stored property 自動補預設。
- **驗收**：生成的 ReadModel 編譯通過。

### G4 — [P1] Event 建構 template 與 plugin-generated init 簽名不符（多餘 `id: UUID()`）
- **症狀**：所有 event 建構 `Missing argument for parameter '<aggIdAlias>'`。編不過。
- **元件**：aggregate / command scaffold template vs `DomainEventGeneratorPlugin`。
- **根因**：scaffold 產 `SomeEvent(id: UUID(), <aggIdAlias>: …, …, occurred: .now)`，但 plugin 生成的 event init **第一參數是 `<aggIdAlias>`、沒有 event 層 `id`**。
- **建議修法**：統一 event 建構 template 與 plugin init 契約（以 `event.yaml` 的 `aggregateRootId.alias` 為首參、不 emit `id: UUID()`）。
- **驗收**：生成的 aggregate full init + 各 command build-event 編譯通過。

### G5 — [P1] read endpoint 預設 path 與 write path 在 router 撞 param 名 → server 啟動即 fatal
- **症狀**：`Fatal error: Route /<agg>/{<aggId>} overrides /<agg>/{<readKey>}`，server 一啟動就 crash（編譯/測試看不出來）。
- **元件**：`/presenter` 預設 path 模板（落到 `openapi.yaml` / bundle `presenters[].endpoint.path`）。
- **根因**：模板 `/<kebab-aggregateRef>/{<readModel.key.field>}/<name>` 把 read key 當「位置2 param」。當 `key.field`（如 `userId`）≠ aggregate id 名（如 `employeeAccessId`）時，與 write path `/<agg>/{<aggId>}/<action>` 在同一 trie 位置出現**不同名 param** → Hummingbird 衝突。
- **建議修法**：`/presenter` 預設 path 在「key.field ≠ aggregate id 名」時改用 literal 區隔段（`/<agg>/<resource>/{key}`，如 `/employee-access/permissions/{userId}`）或不同 resource 根；並文件化此 router 限制。
- **驗收**：生成的 server 能啟動、無 route-override fatal。

### G6 — [P1] read GET response 引用未定義的 `String` schema（dangling `$ref`）
- **症狀**：read endpoint 的 200 response `items: $ref: '#/components/schemas/String'`，但 `components/schemas` 沒有 `String` → openapi 生成/build 風險（dangling ref）。
- **元件**：read renderer（openapi GET response schema）。
- **根因**：array element 用 `$ref` 指向不存在的 `String` schema，而非 inline。
- **建議修法**：array-of-scalar 改 emit inline `items: { type: string }`（或真的定義該 schema）。
- **驗收**：生成的 openapi 自洽、`swift-openapi-generator` 不報 dangling ref。

---

## 2. Skill / 跨 skill bug

### G7 — [P0→P1] domain error catalog 與 transport error catalog 無同步 → 業務錯誤回 503 而非 422
- **症狀**：`/domain-fill`（或人）新增的 domain error（如 `permissionAlreadyExists`）走 HTTP 時回 **503 `serviceUnavailable`**，而非語意正確的 **422**。
- **元件**：`/domain-fill`（加 `<A>Error` + `errors.md`） × `/api`（明文「不寫 openapi.yaml」）× `ApiComponents+<A>ApiError` mapper × `openapi.yaml` 的 `<A>ApiError` enum。
- **根因**：**兩套平行 error 目錄、無同步機制**。domain 目錄（`<A>Error` + `errors.md`，人/domain-fill 擁有）新增 case 後，transport 目錄（openapi `<A>ApiError` → 生成的 `Components.Schemas.<A>ApiError`）不會跟著有。mapper 被迫對 domain 側 exhaustive、卻只能用 transport 側存在的 case → 唯一能編的選擇是 `return nil` → caller `?? .undefinedDomainError` → catch-all → 503。
- **重現**：`/domain-fill` 加一個 bundle 未宣告的 domain error → 跑 `/api` → 打會觸發該 error 的 request → 收到 503 而非 422。
- **建議修法**：補「error catalog → openapi ApiError + mapper」同步流程。最佳是讓 `errors.md` 成為 SSOT、由 renderer 生成 openapi `<A>ApiError` enum + `ApiComponents` mapper；或 `/api` 擴充、或新增 `/error-map` skill。
- **驗收**：新增 domain error 後，生成的 openapi enum 含它、mapper 映射它、HTTP 回 422。

### G8 — [P1] `/test-gen` v2 依賴的 codegen 契約，舊 scaffold 沒有 → 產物編不過
- **症狀**：對 `v0.1.0-phase1k2`（fatalError 世代）生成的專案跑 v2 enabled-red `/test-gen` → 產物 `cannot find 'GenesisTODO' in scope`、`cannot find 'ContextError' in scope` → 整 test target 垮。
- **元件**：`/test-gen` v2 ↔ codegen（`<A>GenesisTODO` enum、`{UC}Usecase` catch-ladder）+ test-gen @Suite 模板。
- **根因**：v2 假設 (a) 每個 aggregate 有 `package enum GenesisTODO`、(b) `{UC}Usecase.execute` catch-ladder 有 `catch let error as GenesisTODO`（讓洞乾淨穿透）、(c) FixtureRenderer 已 codegen `SharedUtility/UsecaseCall/<A>.swift`。舊 scaffold 三者皆無。另：v2 @Suite 模板 import 清單**漏 `import <Ctx>Shared`**（斷言 `ContextError` 需它）、且 `import <contextName>` 假設有 context-named module（實際只有 `<A>Aggregate`）。
- **建議修法**：(a) test-gen 偵測 GenesisTODO 契約存在與否，缺則 fail-loud 提示「需 genesis 重生為新世代」或提供 fallback；(b) @Suite 模板補 `import <Ctx>Shared`；(c) module import 用 `<A>Aggregate` 分支。
- **驗收**：對「新世代 genesis 生成的專案」跑 test-gen → 產物 `swift build --build-tests` 通過。

### G9 — [P2] `/usecase` SKILL.md 偵測字串與 scaffold 實際 emit drift
- **症狀**：`/usecase` 的 idempotent tri-state（未填/已填/半填）判定不可靠。
- **根因**：SKILL.md 說偵測 `fatalError("not implemented")` + `// GENESIS-STUB:`，scaffold 實際吐 `fatalError("TODO(/usecase skill): pattern is …")`。字串完全不同。
- **建議修法**：對齊 SKILL.md 偵測字串與 scaffold template 實際輸出（擇一為準），或改用穩定 marker（固定註解 tag）而非 fatalError 訊息字串。`/domain-fill` 的 `#error("GENESIS-TODO: …")` vs doc 也有類似 drift，一併檢查。
- **驗收**：skill 文件描述的 marker 與 scaffold 實際 emit 一致。

### G10 — [P2] `/domain-fill` 不處理 `fatalError`-form 的洞 → build 綠但 runtime trap
- **症狀**：create 的 convenience-init「從 input 推導 permissions/roles/status」洞，domain-fill 跑完仍是 `fatalError(...)`；因 fatalError 不擋編譯 → build 綠、被誤以為完成、但 create 路徑 runtime 會 trap。
- **元件**：`/domain-fill`（只認 `#error("GENESIS-TODO")`）+ create convenience-init scaffold（用 `fatalError`）。
- **建議修法**：把 create convenience-init 的 derivation 洞統一成 `#error`（擋 build、被 domain-fill 捕捉），或明確納入某 fill skill 範疇。
- **驗收**：生成專案 `swift build` 不會因「未填但編得過」而綠；domain-fill 跑完無遺漏的 runtime-trap 洞。

---

## 3. 工作流 / CLI 缺口

### G11 — [P2] 無 `genesis diff` / 增量重生 → 想加新 scaffold 必須整包重生、洗掉人工填的 code
- **症狀**：要加一個 read endpoint（`/presenter` 寫 bundle → 需 `genesis new` scaffold）時，`genesis new` 只能整包 bootstrap，會覆蓋所有已填的 domain/usecase/api code。`.scaffold-manifest.json` 記了每檔 sha256，但**沒有任何 CLI 子指令消費它**（無 `diff`/safe-apply）。
- **影響**：本 repo 被迫用「`genesis new --output /tmp` 生到暫存 → 手動 splice read-side 新檔」繞過。
- **建議修法**：`genesis diff`（用 manifest sha256 偵測人工編輯）+ 增量 apply / 只加新檔的模式。
- **驗收**：對已填的專案重跑，可只加新增的 scaffold（如新 read endpoint）而不覆蓋人工 code。

### G12 — [P3] `/presenter`（及 read-side skills）預期 canonical schema，但 on-disk bundle 是 Cosmogony raw 格式
- **症狀**：`/presenter` SKILL.md 用 `bundle.readModels[].name` / `bundle.presenters[]`；但 raw bundle 的 readModel 是 `queryName`/`parameters`/`returnType`、`presenters` 為 `null`。skill 直接讀 raw bundle 的 `readModels[].name` / storedFields 會對不到。
- **註**：本 repo 手動依 `/presenter` 文件化的 PresenterSpec schema 寫 `presenters[]` 後，`genesis new` **能正確消費**並生出 read endpoint（證明 presenters[] 寫入端契約 OK）；問題在 skill「讀 raw bundle 取 readModel 欄位」那段與 raw 格式不符。
- **建議修法**：明確規範 read-side bundle-writing skills 操作的是 raw bundle 還是 canonical（`bundle-parse` 輸出），或在 skill 內先 normalize。
- **驗收**：`/presenter` 對 raw bundle 能正確列出/引用既有 readModel 並 append presenter。

### G13 — [P3] `/test-gen` 在 domain 仍 placeholder 時產出無驗證價值的 test（時機）
- **症狀**：domain 還是 placeholder（baseline 空、fake universe、部分 orchestration 仍 stub）時跑 test-gen，多數 scenario 不是 skipped 就是「斷言假資料==假資料」，且 placeholder 下某些 invariant（如 permissionNotMatch）根本觸發不了。
- **建議修法**：test-gen 偵測 domain placeholder（baseline 空、fake universe 標記）時 warn「現在產 test 多無驗證價值，建議 domain 定真後再跑」；文件明確區分「scaffold 可跑」≠「scenario 已覆蓋」。
- **驗收**：對 placeholder domain 跑 test-gen 會出現上述警告。

---

## 4. 開發體驗（文件化即可，非程式 bug）

### G14 — SourceKit 即時診斷對 plugin-generated 型別全是假陽性
- **症狀**：用到 plugin 生成的型別（event 建構、`Operations.*`、`Components.Schemas.*`、`<A>AggregateEventMapper`…）時，SourceKit 報 `Missing argument` / `Cannot find ... in scope` / `has no member`，但 `swift build` 實際編得過。整個 dogfood 反覆誤導（一度把真 bug G4 誤判成假陽性）。
- **根因**：SourceKit 不跑 build plugin。
- **建議**：Genesis 文件/skill 註明「plugin-generated 型別的 SourceKit 即時診斷不可信，ground truth 以 `swift build` 為準」；或探討讓 plugin 輸出可被 SourceKit 索引的型別 stub。

---

## 優先處理建議

| 優先 | 項目 | 為何優先 |
|---|---|---|
| 1 | **G1**（category 前綴靜默斷鏈）| 不報錯、結果錯，最難察覺；read 側整個失效 |
| 2 | **G2 / G3 / G4**（編不過）| 開箱即編不過，每個新專案都中 |
| 3 | **G5 / G6**（server crash / openapi dangling）| 一跑 server / 生 openapi 就壞 |
| 4 | **G7**（503 vs 422 + error catalog 無同步）| contract 與 domain 不一致；結構性誘發 |
| 5 | **G8**（test-gen v2 契約）| 阻擋 test 流程；新舊世代不相容 |
| 6 | G9 / G10 / G11 / G12 / G13 / G14 | drift / 工作流 / 體驗 |

> 共通建議：**`genesis verify` 應擴充**到能抓 G1（前綴一致性）、G2–G4（生成即編譯）、G5（路由不衝突）這類「生成後結構正確性」，把目前要人手動跑 server / 追 KDB 串流才發現的問題，變成自動 gate。
