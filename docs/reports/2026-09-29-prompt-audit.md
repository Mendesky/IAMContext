# 提示稿體檢報告 — IAMContext（2026-09-29）

依 `/claude-api prompt-audit` 流程執行。只產出報告與建議 diff，**未套用任何修改**。建議 diff：`docs/reports/2026-09-29-prompt-audit.diff`。

## 前提假設

- **範圍**：本 repo 的 `CLAUDE.md`、`AGENTS.md`、`GEMINI.md`、`.claude/` 下的 skills 與 commands，以及程式碼中送給模型的提示與工具描述。範圍由 AuditAgent session 代使用者轉達的請求指定。
- **盤點結果**：實際存在的只有 `CLAUDE.md`（31 行，已追蹤）與 `AGENTS.md`（31 行，**未追蹤**）。兩份除第 1、7 行的 agent 名稱外逐字相同。repo 沒有 `GEMINI.md`、`.claude/`、`.codex/`。`Sources/`、`Tests/`、`scripts/` 內 grep `anthropic|claude-|openai|gpt-|system_prompt|systemPrompt` 零命中，Swift 服務不呼叫任何模型。
- **略過的檔案**：使用者層設定（`~/.claude/CLAUDE.md`、`~/.agents/institution/*`、`~/.codex/AGENTS.md`）、上層工作區的 `/Users/abnertsai/JiaBao/Mendesky/CLAUDE.md`、`.ai/contexts/IAMContext/`（被 `.gitignore` 排除的業務 SSOT，由技能讀取，請求未列入），以及位於 repo 外的 `/usecase`、`/readmodel`、`/api` 技能本體。settings 與 `.mcp.json` 依請求不讀，repo 內也不存在。
- **目標模型**：`CLAUDE.md` 由 Claude Code 讀取，以執行本次體檢的 Claude Opus 5.5 為準。`AGENTS.md` 由 Codex CLI 讀取，屬非 Anthropic 模型：Group 1 那類「Claude 模型行為」的判斷不適用，只套用與模型無關的 Group 2（事實過時、檔案間矛盾）。
- **來源追溯**：`CLAUDE.md` 只有一筆歷史 `8ee15f6`（2026-06-10，Genesis 骨架匯入）。`AGENTS.md` 未進版控，無歷史可查。
- **產物位置**：repo 原本沒有 `docs/reports/`，專案 `CLAUDE.md` 也沒有報告存放慣例，因此依請求新建 `docs/reports/`。

## 摘要

兩份指令檔都寫於 6 月 Genesis 骨架產生當下，之後專案已經長大，但檔案沒跟上。影響最大的三項：

1. **`/readmodel` 那行說骨架「不會產生 `projection-model.yaml`」**，而 repo 現在有兩份，EmployeeAccess 與 Role 各一份。讀到這行的 agent 會以為讀取模型沒有宣告檔，可能自己另造一套。
2. **開頭說「專案在補完所有洞之前無法編譯」**，但 `Sources/` 已經沒有任何 `GENESIS-TODO`，`swift build` 是綠的。把開發起點的狀態寫成現況，會讓 agent 誤判專案仍處於骨架階段。
3. **「禁止手改」那條規則的適用範圍已經模糊**。`docs/tasks/` 現在同時放 Genesis 產生的 use case 文件與人寫的實作規格，而規則裡的 `(D15 Option D)` 在本 repo 會撞到角色討論檔中另一個 D15。前者涉及放寬禁令，只標記不改；後者可直接刪。

| 分組 | 發現數 |
|---|---|
| Group 1 過時的提示寫法 | 0。僅有的兩處強調都附了理由，屬保留清單 |
| Group 2 設定檔的事實過時與矛盾 | 3 項進 diff、1 項標記 |
| Group 3 工具描述 | 不適用，repo 內沒有工具定義 |
| Group 4 請求設定與架構 | 不適用，repo 內沒有組 request 的程式 |
| 無法對應到既有 pattern 的觀察 | 2 項標記，列於最後 |

---

## 發現

### F1 — `/readmodel` 說不會產生 `projection-model.yaml`，repo 已有兩份

| 欄位 | 內容 |
|---|---|
| **位置** | `CLAUDE.md:10`、`AGENTS.md:10` |
| **原文** | `` - `/readmodel <ReadModel>` — generate read-model projector files (not yet supported by this scaffold; Phase 1.c does not write `projection-model.yaml`). `` |
| **Pattern** | Group 2 — Volatile specifics（事實宣稱與 repo 矛盾） |
| **為何過時** | `Sources/EmployeeAccessAggregate/projection-model.yaml` 與 `Sources/RoleAggregate/projection-model.yaml` 都存在，`Usecase/Projector/` 下已有 GetPermissions、GetPermissionHolders、GetRoleHolders、GetRoles 等投影器。括號內描述的是 Genesis Phase 1.c 當時的限制，不是現況。 |
| **信心** | 高，repo 本身直接反證 |
| **動作** | `rewrite`：`` - `/readmodel <ReadModel>` — generate read-model projector files. Read models are declared in each aggregate's `projection-model.yaml` (e.g. `Sources/EmployeeAccessAggregate/projection-model.yaml`); the existing projectors under `Usecase/Projector/` show the layout. `` |

### F2 — 開頭把骨架階段的「無法編譯」寫成現況

| 欄位 | 內容 |
|---|---|
| **位置** | `CLAUDE.md:3`、`AGENTS.md:3` |
| **原文** | `` The generated domain code marks unfilled business logic with compile-time holes (`#error("GENESIS-TODO: ...")`) — the project will NOT compile until each hole is filled (this is intentional: an aggregate with unimplemented domain logic should not build). `` |
| **Pattern** | Group 2 — Volatile specifics（事實宣稱與 repo 矛盾） |
| **為何過時** | `grep -rn 'GENESIS-TODO' Sources/` 為 0 筆，`swift build` 通過，所以「專案補完前無法編譯」已不成立。機制本身仍有價值：日後重新產生程式碼時，洞會再讓編譯失敗。所以改寫成描述機制，不描述當下狀態。 |
| **信心** | 高，repo 本身直接反證 |
| **動作** | `rewrite`：`` Genesis marks unfilled business logic in generated code with compile-time holes (`#error("GENESIS-TODO: ...")`), so an aggregate with unimplemented domain logic does not build; fill a hole (say the domain logic, the skill/LLM writes it) and its `#error` disappears. Business-logic guidance lives in `.ai/contexts/IAMContext/<Aggregate>/`. ``（第一句的 Genesis 版本與 bundle id 保留不動） |

### F3 — `(D15 Option D)` 是沒有出處的決策編號，且與本 repo 另一個 D15 撞號

| 欄位 | 內容 |
|---|---|
| **位置** | `CLAUDE.md:23`、`AGENTS.md:23` |
| **原文** | `` `docs/tasks/<UC>.md` (when present) is **100% machine-rendered, hand-edits forbidden** (D15 Option D). `` |
| **Pattern** | Group 2 — History narratives（規則後面掛著事件或決策編號） |
| **為何過時** | 規則的效力來自它規定的行為，不需要編號撐腰。這個 D15 指的是 Genesis 內部的決策，repo 裡沒有出處。本 repo 的 `docs/discussions/2026-08-06-role-aggregate.md:57` 另有一個 D15，內容是「roleId 由 aggregate 自行生成」，讀者會對到錯的決策。 |
| **信心** | 中。pattern 有文件依據；撞號由 repo 可證，但編號本身不會造成錯誤行為 |
| **動作** | `rewrite`：刪掉括號，禁令與粗體原樣保留：`` `docs/tasks/<UC>.md` (when present) is **100% machine-rendered, hand-edits forbidden**. `` |

### F4 — 「禁止手改」的適用範圍與 `docs/tasks/` 現況不符（只標記）

| 欄位 | 內容 |
|---|---|
| **位置** | `CLAUDE.md:23`、`AGENTS.md:23` |
| **原文** | 同 F3 |
| **Pattern** | Group 2 — Volatile specifics |
| **為何標記** | `docs/tasks/` 現在有兩種檔案。Genesis 產生的 use case 文件有 `useCase:` frontmatter，例如 `assignRoles.md`、`grantPrivilege.md`。人寫、供 `/pickup` 使用的實作規格則沒有，例如 `role-aggregate.md`、`role-permission-composition.md`，另有 `registry/`。其中 `get-permission-holders.md` 以 use case 命名，卻是人寫的（commit `fa86070`），落在 `<UC>.md` 這個描述裡。規則沒寫要怎麼區分，讀者可能把禁令套到規格檔上，或反過來把它當成整目錄都能改。 |
| **信心** | 中 |
| **動作** | `flag`，不進 diff。要修就得改變一條禁令的適用範圍，依審查規則由使用者決定。可選的方向有兩個：把規則限定為「帶 `useCase:` frontmatter 的檔案」，或把人寫的規格移到別的目錄。 |

---

## 標記（無法對應到既有 pattern，或無法在 repo 內查證）

- **`CLAUDE.md:7-11` 與 `AGENTS.md:7-11` 提到的 `/usecase`、`/readmodel`、`/api` 技能。**這些是安裝在 repo 外的工具，依審查規則不查證。附帶觀察：這次 session 的技能清單裡沒有這三個名字。若它們已不存在，第 5 到 11 行整段都要改寫。這需要你確認，信心低。
- **缺少現況脈絡（不是過時寫法，只是提醒）。**兩份檔都只描述 Genesis 骨架，沒提到後來人手加入的 `RoleAggregate`。`.scaffold-manifest.json` 裡 `RoleAggregate` 零筆，這符合第 31 行「只記錄 Genesis 產生的檔」的描述，並不矛盾。另外也沒寫到：本機 HTTP 24202 與 gRPC 24203、啟動時必須設定 admin 與 gRPC token、整合測試要連本機 KurrentDB `localhost:2113`、projection 要用 `bash scripts/projection.sh` 部署。這些在專案記憶與規格檔裡都有，要不要補進指令檔由你決定。信心低。

## 保留、未列為發現的內容

- `CLAUDE.md:3` 的 `NOT` 與 `CLAUDE.md:23` 的粗體禁令：都是真實限制，旁邊都附了理由（「故意讓未實作的 aggregate 無法編譯」「文件由機器產生」）。屬保留清單第 1、5 項。
- `CLAUDE.md` 與 `AGENTS.md` 重複：兩份內容一致，只差 agent 名稱，屬於「運作中的重複」（保留清單第 8 項），不建議合併。但 `AGENTS.md` 未進版控，diff 對兩份各給同樣三個 hunk，要一起改才不會分歧。
- `SSOT discipline` 表（第 15-21 行）、Adapter 與 Manifest 段（第 25-31 行）：提到的 `.ai/contexts/IAMContext/{EmployeeAccess,Role}/`、`swift-adapter.yaml`、`.scaffold-manifest.json` 都存在。`architecture.md §6.2` 與 `genesis diff` 指向 repo 外，不查證。

## 驗證方式

- 每一條事實都在 repo 內查過：`grep -rn GENESIS-TODO Sources/`、`ls -ld Sources/*/projection-model.yaml`、`ls -ld .ai/contexts/IAMContext/...`、`grep -rn D15`、`docs/tasks/*.md` 的 frontmatter 與 git log。
- diff 是在暫存副本上修改後產生的，並對 repo 乾跑過 `git apply --check`，兩份檔都通過。repo 內的 `CLAUDE.md` 與 `AGENTS.md` 未被修改。
- 可以只套其中一份：`git apply --include=CLAUDE.md docs/reports/2026-09-29-prompt-audit.diff`。
