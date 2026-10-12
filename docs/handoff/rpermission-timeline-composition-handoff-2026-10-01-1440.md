> 2026-10-01 部署前唯讀檢查產出。使用者決定先在本機測試，共用開發環境部署暫緩。
> 阻擋項 B1（建檔語意）已修正：建立 profile 改為重設起點，開發環境 411 人離線比對 0 差異。
> 文中 scratchpad/preflight-2026-10-01/ 的比對腳本與快照只存在於當時的 session 暫存目錄；之後部署前請重跑一次唯讀檢查，重新產生快照。

# IAMContext 新版（有效權限時間軸重播）部署前檢查與 Runbook

檢查日期：2026-10-01。全程唯讀：KurrentDB 只做 HTTP GET；遠端主機只執行 `true`；GitHub 只讀；沒有 push、tag、merge、compose up。
已讀＋遵循要點：已讀 IAMContext/CLAUDE.md、Deployment/CLAUDE.md、Deployment/AGENTS.md；遵循「契約變更 IAM 端先行」「compose 只改 image tag、用 docker compose config 驗證」「已內嵌的祕密不外洩、不複製」；DevCommon.yaml 只用 `grep -c` 取計數，未讀內容。

證據檔都在 `preflight-2026-10-01/`（同目錄的子資料夾）：
- `api-snapshot-all.json`：部署前 411 位員工的目前有效權限（來自開發環境 HTTP GET）。
- `sim-new.json` / `sim-old.json`：依事件資料離線模擬的新版／舊版結果。
- `sim-diff-users.json`、`users-real-gain.json`、`gained-in-catalog.json`：差異清單。
- `postdeploy-compare.py`：部署後一鍵比對（只 GET）。
- `simulate.py`、`compare.py`、`catalog.py`：模擬與比對程式（內含我這次 session 的 scratchpad 絕對路徑，重跑要改 `S=`）。
- `docker-build-evidence.txt`：本機 docker build 輸出摘要。

---

## 0. 結論

### 阻擋項（部署前必須由人決定）

**B1　新版會改變開發環境 353／411 位員工的有效權限，且全部是增加；其中 143 人增加的是目前 catalog 內真實存在的權限。**
- 這不是規格預期的差異（規格只預期 D4／D5：角色移除權限、先撤銷後入角色），規格的「上線前資料比對」要求「無法解釋的差異先停下回報」，這裡就是。
- 根因：舊版 `GetPermissionsPresenter.when(UserAccessProfileCreated)` 是**覆寫**（`readModel.permissions = Array(event.permissions)`，Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissions/GetPermissionsPresenter.swift:71-76），新版 `PermissionTimeline.replay` 對 `profileCreated` 是**聯集**（Sources/EmployeeAccessAggregate/Entity/PermissionTimeline/PermissionTimeline.swift:111-114；規格 §d 表第一列）。
- 資料面：765 筆 `UserAccessProfileCreated` 對應 411 個 userId；354 位員工有**兩筆**建檔事件（兩個 employeeAccess stream，位置約 1.8k 與約 120k，應是兩次匯入）。第一個 stream 的授權（最多 264 筆）被舊版的第二次建檔覆寫清掉；新版聯集後全部回來。
- 規模（離線模擬，且已用即時 API 驗證模擬正確：舊版模擬結果 == 開發環境目前 API 回傳，411／411 完全一致）：
  - 新舊相同 58 人；變多 353 人；變少 0 人。
  - 增加量分布：2 筆 140 人、74 筆 69 人、264 筆 141 人、其他 3 人。
  - 增加的 264 種權限中 190 種在目前 catalog（336 個 rawValue），74 種是改名前的舊名（`OpportunityContext.AuditQuoting.*` 52、`CompanyRegistrationQuoting.*` 22，不在 catalog，沒有 endpoint 會檢查）。
  - 143 位員工會多出至少 1 個真實權限，例如 `OpportunityContext.QuotingCaseGrouping.*`（143 人）、`Storage.UploadEmbeddedImage`（143 人）。
- 需要的決定（擇一，不是我能代決）：
  - (a) 確認「事件聯集」才是想要的語意，接受開發環境這批權限擴張，並在部署通知裡說明。
  - (b) 改規格與引擎：讓第二次 `UserAccessProfileCreated` 對該員工視為重設（或改成依 employeeAccess stream 分區重播），使新版與舊版在既有資料上一致。改完用 `simulate.py` 重新比對，目標是「模擬新版 == 目前 API」411／411。
  - (c) 清資料（對舊 stream 補撤銷事件或廢棄），屬資料修補，不在本 runbook 範圍。
- 正式環境（<prod-host>，Common.yaml 也是 1.4.0）若有同樣的兩次匯入歷史，會出現同樣差異；我沒有碰正式環境。

### 其他結論（不阻擋，但 runbook 依此設計）

1. **release 失敗原因**不是同一個，而且 PR #24 之後 push 新 tag 預期能建出映像（見 §1）。
2. **projection 不要用整批 `scripts/projection.sh`**：它不能指定單支、delete 會連 emitted streams 一起刪、整批重跑期間既有 projection 的 link stream 是空的，`getPermissions` 會回空權限。只新建 `IAM_GetRoles`、`IAM_RoleHolders` 可行，既有兩支不用動（開發環境上的原始碼與 repo 檔案逐位元組一致）（見 §1、§2 的指令）。
3. **fail-closed 掃描結果：零風險**。`$ce-IAMEmployeeAccess` 的 190,713 筆事件只有 5 種型別，全部在「處理」清單內；`$ce-IAMRole` 不存在（無任何角色事件）；411 個 `IAM_GetPermissions-<userId>` 的 190,713 筆 link 全部可解析。
4. 本機改動是 32 個未 commit 檔案，疊在**已合併**的 `feat/role-aggregate`（cf67aca，即 PR #25 的 head）上，落後 origin/main 三個 commit（只差 Dockerfile 的釘版）。要先換到以 origin/main 為底的新分支再 commit。
5. 存取權：GitHub 兩個 repo 都是 ADMIN；可用 `ssh <deploy-user>@<dev-host>` 金鑰登入；但 ssh config 沒有這台的別名，預設使用者會被拒。

---

## 1. 五項檢查結果與證據

### 1. release 為何失敗

| tag | run | 日期 | 失敗位置 | 原因 | 映像有沒有推出去 |
|---|---|---|---|---|---|
| 1.1.0 | 32684618561 | 2026-08-24 | guard job（0 個 step，build job 被 skipped） | annotation：「recent account payments have failed or your spending limit needs to be increased」＝GitHub 帳務問題 | CI 沒建；registry 的 1.1.0 是之後才出現（createTime 05:48Z，run 在 02:54Z） |
| 1.2.0 | 34562929890 | 2026-09-11 | Build and push 的最後一步「exporting to GitHub Actions Cache」 | GitHub Actions cache 服務暫時掛掉：`failed to parse error response 400: Our services aren't available right now`（log 行 `#22 ERROR`）；映像已經 `pushing manifest ... iam-context:1.2.0` 完成 | 有推（日誌 04:43:22Z） |
| 1.3.0 | 34567871662 | 2026-09-11 | 同上（`#21 ERROR`） | 同上；日誌顯示 `Build complete! (281.28s)`、`pushing manifest ... 1.3.0` 與 `latest` | 有推（06:03:28Z），`latest` 目前指向 1.3.0 |
| 1.4.0 | 35813670284 | 2026-09-23 | Build and push 的 `swift build -c release --static-swift-stdlib` | Dockerfile 用 `swift:latest`（已是 6.4.0），靜態連結 Foundation 失敗：`undefined reference` 對 `libFoundation.a(CharacterSet.swift.o)`、`swift_ures_*`（ICU），`permission-catalog-gen` 連結失敗（swiftlang/swift-package-manager#10564） | 沒推；registry 的 1.4.0（digest sha256:a4897a5a…，createTime 2026-09-23 03:53Z）是 run 失敗後約 34 分鐘由別的途徑推上去的，不是這支 workflow 產出 |

證據指令：`gh run list --workflow release-docker.yml`、`gh run view <id> --log-failed`（log 存在我的 scratchpad，`log-<id>.txt`）；registry：`gcloud artifacts docker tags list <registry>/iam-context`（唯讀，額外執行；列出 1.0.0、1.0.0-dev.0、1.1.0、1.2.0、1.3.0、1.4.0、latest）。

**PR #24 合併後，push 新 tag 能否成功？預期能。** 證據：
- origin/main 的 Dockerfile 釘 `swift:6.2.4`（第 6 行）與 `swift:6.2.4-slim`（第 35 行）。注意：目前本機工作樹的 Dockerfile 還是舊的 `swift:latest`（第 2、30 行），因為分支落後 main。
- PR #24 描述：本機 `docker build` exit 0，且用該映像起容器打 `GET /employee-access/permissions/{userId}` 得 HTTP 200。
- 我獨立重建：把「工作樹（含未 commit 的時間軸程式）＋ origin/main 的 Dockerfile」做成快照，在 OrbStack 本機 `docker build`：`Build complete! (158.02s)`、exit 0、無 error（`docker-build-evidence.txt`）。限制：這是 linux/arm64，CI 是 linux/amd64；只編 release 產品，沒編測試 target。
- 1.2.0／1.3.0 在同一類 self-hosted x86_64 runner 上用當時的 `swift:latest`（digest dd115b2…）成功編完（約 281 秒）；失敗的只有 6.4.0 這一種工具鏈。
- 其他會讓它變紅或不出映像的原因：
  1. **GHA cache 匯出失敗會讓 run 變紅但映像已推**（1.2.0／1.3.0 的情形）。判斷成敗要看 registry 有沒有該 tag，不要只看 run 顏色。可考慮把 `cache-to` 加 `ignore-error=true`（workflow 改動，屬另一個 PR，未做）。
  2. **tag 若不在 origin/main 上，guard 的 `on-main=false`，build-push 被 skip，run 反而是綠的但沒有映像。** 所以要先 merge、再對 merge commit 打 tag。
  3. secrets：repo 有 `GCP_SA_KEY`、`RELEASE_SSH_KEY`、`TEAMS_WEBHOOK_URL`（只看名稱）；1.4.0 的 run 裡 SSH agent、Artifact Registry 登入、buildx 都成功，只有 build 失敗，所以 secrets 在 9/23 是有效的。
  4. runner：workflow 用 `runs-on: [self-hosted]`；repo 層沒有 runner，org 層我無權限列出（HTTP 403，需要 admin:org），**runner 此刻是否在線未知**。CI 另一個 workflow 的 runner 標籤是 `self-hosted, linux, X64, dev, 55`，就在 <dev-host> 這台。
  5. 帳務：1.1.0 曾因 spending limit 完全不啟動；之後有正常跑，建議打 tag 前看一下 Actions 頁有無該 annotation。
  6. 還有一個 open PR #23（`dev/dockerfileSwift64Bundle`，拿掉 `--static-swift-stdlib` 的另一條路）；與 #24 同改 Dockerfile，兩者不能都合，這次不要碰。
- main 沒有 branch protection（API 回 404 Branch not protected），CI 通過與否不是強制條件，要靠自己確認。

### 2. projection 部署方式（scripts/projection.sh）

- **能不能只部署指定幾支？** 不能。沒有參數；`PROJECTIONS_DIR="projections"`（第 12 行）寫死且相對於目前工作目錄，第 180 行 `find "$PROJECTIONS_DIR" -name "*Projection.js"` 全部處理。KDB 位置可用環境變數 `KDB_HOST`／`KDB_PORT`／`KDB_URL` 覆寫；帳密寫死在腳本裡（預設帳密）。變通：在暫存目錄建一個只含目標兩檔的 `projections/`，從那裡執行腳本；或直接 curl。
- **projection 名稱規則**：`basename "$file" Projection.js`，所以 `IAM_GetRolesProjection.js` → `IAM_GetRoles`，`IAM_RoleHoldersProjection.js` → `IAM_RoleHolders`。
- **delete 會不會連帶刪 emitted streams？會。** 第 73-77 行：`deleteStateStream=true`、`deleteCheckpointStream=true`、`deleteEmittedStreams=true`。已存在的 projection 的處理流程是 disable → delete（含 emitted streams）→ create。開發環境上兩支既有 projection 的 config 都是 `emitEnabled:true, trackEmittedStreams:true`，所以刪除會清掉它們產生的 `IAM_GetPermissions-<userId>`（411 個 stream、190,713 筆 link）與 `IAM_GetPermissionHolders-*`。
- **整批重跑時 `getPermissions` 會不會查不到？會。** 重建期間 link stream 被清空、要從 `$ce-IAMEmployeeAccess` 的 190,713 筆事件重新處理（耗時沒有實測）。stream 不存在時：HTTP 回 404；gRPC 的 `PermissionsService.getPermissions` 對 `notFound` 回**成功＋空權限清單**（Sources/IAMContextServer/PermissionsService.swift:45-51），消費端會判 deny → 403。stream 重建到一半的員工只有事件前綴，權限不完整。消費端有 60 秒 TTL 快取（IAMContext memory 記載），只能緩衝一小段。新版服務在這種狀態下行為相同（`effectivePermissions(userId:)` 回 nil → notFound → 空清單）。
- **只新建 `IAM_GetRoles` 與 `IAM_RoleHolders`、既有兩支不動，可行。** 前提都已驗證：
  - 開發環境目前只有 `IAM_GetPermissions`（version 6）與 `IAM_PermissionHolders`（version 0）兩支 IAM_ projection，兩支都 Running、progress 100、checkpoint `$ce-IAMEmployeeAccess: 190712`（跟到最新）。
  - 這兩支在開發環境的 query 原始碼與 origin/main、工作樹的 `projections/IAM_GetPermissionsProjection.js`、`IAM_PermissionHoldersProjection.js` 用 `/usr/bin/diff` 比對**完全相同**；本次也沒有改這兩個檔。
  - 新建不存在的兩支時，腳本走「Projection 不存在，直接建立」分支，不會執行 disable／delete。
  - 新版服務在這兩支缺席時只是反查候選人變少，不會報錯（規格失敗路徑）；目前也沒有角色，所以沒有實質影響。

**確切指令（不要現在執行；在 §2 的 Phase 4 才用）**

方式 A，用既有腳本（只含兩個檔案的暫存目錄；腳本須在已 merge 的 main 上取檔）：
```bash
T=$(mktemp -d) && mkdir "$T/projections" \
&& cp <workspace>/IAMContext/projections/IAM_GetRolesProjection.js \
      <workspace>/IAMContext/projections/IAM_RoleHoldersProjection.js "$T/projections/" \
&& cd "$T" \
&& KDB_HOST=<dev-host> KDB_PORT=2113 bash <workspace>/IAMContext/scripts/projection.sh
```
方式 B，直接 curl（與腳本 create 參數相同，不含 delete 分支，較不會誤刪）：
```bash
KDB=http://<dev-host>:2113
# 先確認這兩支真的不存在（應只列出 IAM_GetPermissions、IAM_PermissionHolders）
curl -s -u <kdb-user>:<kdb-password> "$KDB/projections/continuous" | jq -r '.projections[]|select(.name|startswith("IAM_"))|.name'
for n in GetRoles RoleHolders; do
  curl -sS -u <kdb-user>:<kdb-password> -w '\nHTTP %{http_code}\n' \
    --data-binary @<workspace>/IAMContext/projections/IAM_${n}Projection.js \
    "$KDB/projections/continuous?name=IAM_${n}&type=js&enabled=true&emit=true&trackemittedstreams=true"
done   # 每支期望 HTTP 201
```
預期副作用：`IAM_RoleHolders` 會回補 383 筆既有員工事件（382 筆 `RolesAssigned`＋1 筆 `RolesRevoked`），產生 8 個 `IAM_GetRoleHolders-<舊角色名>` stream（舊的中文字串 roleId，例如「一般使用者」）；`IAM_GetRoles` 讀的 `$ce-IAMRole` 目前不存在，應停在 Running 且沒有輸出。

### 3. 開發環境 KurrentDB 唯讀檢查（KurrentDB 26.1.1.3690，單節點 leader，全部 HTTP GET）

**3a　projection 狀態**（`GET /projections/continuous`，共 124 支 continuous）
| 名稱 | status | progress | version | 位置 |
|---|---|---|---|---|
| IAM_GetPermissions | Running | 100.0 | 6 | `$ce-IAMEmployeeAccess: 190712` |
| IAM_PermissionHolders | Running | 100.0 | 0 | `$ce-IAMEmployeeAccess: 190712` |
沒有 `IAM_GetRoles`、`IAM_RoleHolders`。系統 projection（`$streams`、`$by_category`、`$by_event_type`、`$stream_by_category`、`$by_correlation_id`）都 Running 100。

**3b　角色事件**：`GET /streams/$ce-IAMRole` → 404；`$et-RoleCreated`、`RoleRenamed`、`RoleDescriptionUpdated`、`RolePermissionsAdded`、`RolePermissionsRemoved`、`RoleDeleted` 全部 404；`IAM_GetRoles-all` 404。結論：沒有任何角色事件（符合預期）。

**3c　fail-closed 掃描**（`GET /streams/$ce-IAMEmployeeAccess/<n>/forward/4096?embed=rich` 分頁；位置 0–190712 共 190,713 筆全部取到、無缺漏、全為 JSON、分布於 765 個 `IAMEmployeeAccess-*` stream）
| 事件型別 | 筆數 | 新版處置 |
|---|---|---|
| PrivilegeGranted | 189,054 | 處理 |
| UserAccessProfileCreated | 765 | 處理 |
| PrivilegeRevoked | 511 | 處理 |
| RolesAssigned | 382 | 處理 |
| RolesRevoked | 1 | 處理 |
「明確忽略」清單（員工側 `UserPromoted`、`DepartmentTransferred`、`EmployeeAccessDeleted`；角色側 `RoleRenamed`、`RoleDescriptionUpdated`）在資料中出現 0 次（`$et-` 查證亦 404）。**不在清單內的型別：無。** 對照來源：Sources/EmployeeAccessAggregate/Adapter/PermissionTimeline/PermissionTimelineService.swift:99-113、Sources/RoleAggregate/Adapter/RoleDirectory/RoleAggregateDirectory.swift:60-71、兩個 `event.yaml` 的登記型別（員工 8 種、角色 6 種）。
補充驗證：
- 411 個 `IAM_GetPermissions-<userId>` 逐一讀完：全部 200，link 合計 190,713 筆（與 `$ce` 筆數相同，無重複、無缺漏），沒有無法解析（`$>` 或目標不在 `IAMEmployeeAccess-*`）的 link。
- 對全部 190,713 筆做欄位形狀檢查（通用欄位 `employeeAccessId`、`id`、`userId`、`occurred`，加各型別必要欄位）：全數通過。這不等於 Swift 解碼一定成功，但舊版對授權／撤銷事件的解碼已被 411／411 的 API 一致性間接證明。
- 角色 ID：`RolesAssigned`／`RolesRevoked` 引用 8 種 roleId，全是舊的中文字串（「一般使用者（總所）」等），沒有對應 `IAMRole-*` stream。新版對不存在的角色 stream 會 `resourceNotFound` 並略過，內容視為空集合（規格 §d：「未知 roleId（舊字串）永遠是 C[r] = ∅」），不會 503。225 位員工有這類事件。

**3d　$ce-IAMRole 為零時，新舊版理論上為什麼相同，以及實測例外**
- 為什麼理論上相同：兩版的有效權限都是「員工直接事件」加上「持有角色的內容」。角色內容在兩版都是空集合（沒有角色 stream），所以只剩直接事件；`PrivilegeGranted` 聯集、`PrivilegeRevoked` 差集，兩版語意一致。
- 例外：兩版對 `UserAccessProfileCreated` 的語意不同（覆寫 vs 聯集，見 B1），而本環境有 354 位員工有兩筆建檔事件。所以**實測不相同**，而不是相同。
- 驗證方法：以事件資料離線重播（`simulate.py`），舊版模擬值與開發環境目前 API 回傳 411／411 一致；新版模擬值有 353 人不同（全部增加）。
- 抽查 3 位（再加 1 位對照），現值如下（`GET http://<dev-host>:24202/employee-access/permissions/{userId}`，HTTP 200；sha 是排序後權限清單的 SHA-256 前 16 碼；411 人完整現值在 `api-snapshot-all.json`）：

| 情形 | userId | 現值筆數 | sha256[:16] | 新版模擬筆數 | 新增筆數 |
|---|---|---|---|---|---|
| 不受影響（單一建檔） | 員工 A | 264 | 56301b230efe9cca | 264 | 0 |
| 雙建檔，只多 2 筆舊名 | 員工 B | 385 | e23fec229ca3b8b3 | 387 | 2（皆不在 catalog） |
| 雙建檔，多 74 筆 | 員工 C | 294 | d82df6a235e669d3 | 368 | 74（皆不在 catalog，舊名） |
| 雙建檔，多 264 筆（對照） | 員工 D | 78 | 24cd649e4fd5b640 | 342 | 264（其中 190 筆在 catalog） |

基準延遲：事件最多的員工（員工 E，1,246 筆事件）現在 GET 約 41–49 ms；部署後可比對。

### 4. 存取權
- `gh repo view Mendesky/IAMContext --json viewerPermission` → **ADMIN**（public repo）；`Mendesky/Deployment` → **ADMIN**（private）。gh 登入帳號 abner-tungchi，scopes：repo、read:org、gist、admin:public_key（無 admin:org，所以看不到 org runner）。
- Deployment repo（<workspace>/Deployment）：
  - remote：`origin  git@github.com:Mendesky/Deployment.git`；目前分支 `main`。（CLAUDE.md 寫「active branch is test」已過時：本機 `test` 是 ahead 1／behind 140。）
  - 本機 `main` **落後 origin/main 5 個 commit**，這 5 個都改 Common.yaml／DevCommon.yaml（opportunity-context 1.6.0、mendesky-web 1.6.3、HDV 2.12.0-beta.0、`OC_GRPC_AUTH_TOKEN`），其中 DevCommon.yaml 有 +4/−3。改 DevCommon 前必須先 `git pull --ff-only`。
  - 未 commit：`M LocalBuildCommon.yaml`（+2）；未追蹤：`AGENTS.md`、`BetaCommon.yaml`、`CLAUDE.md`、`Common.yaml.2026-09-11.bak`、`Databases.yaml`、`DevCommon.yaml.2026-09-11.bak`、`HDVContextPostgreSQL/`、`docs/`、`resource/`。`DevCommon.yaml` 本機已追蹤且無修改。所以 commit 時**只 `git add DevCommon.yaml`**，不要 `git add -A`（`.bak` 檔含祕密）。
  - DevCommon.yaml 的計數（只用 `grep -c`）：`iam-context:1.4.0` 1 處；`IAM_DEBUG_FULL_PERMISSIONS` 1 處且值為 0／false（與即時 API 回每人不同權限一致，沒有被 debug 全開）；`IAM_GRPC_AUTH_TOKEN` 6 處、`IAM_ADMIN_API_TOKEN` 1 處、兩個 `*_DISABLED` 0 處。Common.yaml（正式）也是 `iam-context:1.4.0`，不要動。
  - 1.4.0 → origin/main 的差異：Dockerfile、Package.swift、`IAMContextServer.swift`、`PermissionsService.swift`，伺服器讀取的環境變數集合**完全相同**（ESDB_URL、IAM_ADMIN_API_TOKEN、IAM_GRPC_AUTH_TOKEN、IAM_DEBUG_FULL_PERMISSIONS、各 *_DISABLED、PORT、GRPC_PORT），所以 compose 不需要新增環境變數。
- ssh：本機 ssh 設定沒有開發主機的別名，用預設使用者登入會被拒；改用部署帳號 `<deploy-user>` 以金鑰登入成功。
  - 以預設使用者登入 `<dev-host>`：`Permission denied (publickey,password)`。
  - 以 `<deploy-user>@<dev-host>` 登入並只執行 `true`：exit 0。
- gcloud：已安裝（gcloud）；帳號：本機已登入可存取 Artifact Registry 的帳號（帳號名稱不記錄在 repo）

---

## 2. Runbook：本機未 commit → 開發環境跑新版並部署好 projection

圖例：**[本機]** 不動共用狀態；**[共用]** 會改變共用狀態，需要明確同意再做。每步列驗證與回滾。

### Phase 0　先解 B1　[本機／決策]
1. 決定 B1 走 (a) 接受、(b) 改引擎、(c) 清資料（見 §0）。未決定前不要進 Phase 2 之後。
2. 若走 (b)：改規格與 `PermissionTimeline.replay`，補「同一 userId 兩筆建檔」的測試；用 `simulate.py` 的新版語意重算，目標是模擬新版 == `api-snapshot-all.json` 411／411。
3. 若走 (a)：把「353 人增加權限、143 人增加真實權限」寫進 PR 描述與部署通知，並在 `docs/integration` 的相容性段落補一句（規格 Step 8 已有「既有資料不需遷移」那句，需改成會有差異）。

### Phase 1　本機準備　[本機]
1. 換到以 origin/main 為底的新分支，帶著未 commit 的改動：
   ```bash
   cd <workspace>/IAMContext
   /usr/bin/git fetch origin
   /usr/bin/git diff HEAD origin/main --stat      # 預期只有 Dockerfile 一檔（已驗證）
   /usr/bin/git switch -c feat/permission-timeline origin/main
   /usr/bin/git status --short | wc -l            # 預期仍是 32
   ```
   驗證：`/usr/bin/git diff origin/main --stat -- Dockerfile` 為空（本機改動不碰 Dockerfile）。回滾：`/usr/bin/git switch feat/role-aggregate`（改動會跟著走）。
2. 本機 gate（規格 Step 9／驗收標準）：`/usr/bin/swift build --build-tests`，再依規格啟動本機 KurrentDB 跑 Swift Testing。注意這會在工作樹寫 `.build/`（已 ignore）。我沒有跑測試。
3. 依 `/commit` 分組 commit（程式／測試／文件分開）。驗證：`/usr/bin/git log --oneline origin/main..HEAD`。回滾：`/usr/bin/git reset --soft origin/main`（未 push 前）。

### Phase 2　PR 與合併　[共用：push、PR、merge]
1. `/usr/bin/git push -u origin feat/permission-timeline`，開 PR 到 main。
2. 等 `swift build testing`（self-hosted `[self-hosted, linux, X64, dev, "55"]`，標籤含 dev、55，CI log 的 runner 路徑是 <deploy-home>/actions-runner-*，推測就是 <dev-host> 這台；它自起一個拋棄式 KurrentDB 容器跑測試）通過。驗證：`gh pr checks <n>`。main 沒有保護規則，CI 紅了也能 merge，所以要自己卡。
3. review 後 merge。驗證：`gh pr view <n> --json mergeCommit,state`；確認 `git merge-base --is-ancestor <mergeSha> origin/main`。回滾：開 revert PR（不改寫歷史）。
4. 不要同時 merge PR #23。

### Phase 3　打 tag 並建映像　[共用：tag、registry]
1. 版號用 `1.5.0`（1.4.0 已存在，不可重用；`latest` 目前指向 1.3.0，打 1.5.0 會把 `latest` 搬到新映像，目前沒有任何 compose 引用 `latest`）。
2. 對 **merge commit** 打 tag：
   ```bash
   /usr/bin/git fetch origin && /usr/bin/git tag -a 1.5.0 <mergeSha> -m "1.5.0" && /usr/bin/git push origin 1.5.0
   ```
3. 驗證（不要只看 run 顏色）：
   ```bash
   gh run list --workflow release-docker.yml --limit 1
   gh run view <id> --log-failed | tail -40        # 若紅，先判斷是否又是 cache 匯出失敗
   gcloud artifacts docker tags list <registry>/iam-context --format="value(tag.basename(),version.basename())"
   ```
   期望 registry 出現 `1.5.0`。預期建置時間約 5 到 6 分鐘。
4. 失敗處理：如果 guard 被 skip（tag 不在 main）→ 刪遠端 tag 後重打（`git push origin :refs/tags/1.5.0`，這是共用狀態的刪除，需同意）；如果是編譯錯 → 修好後用新 tag `1.5.1`，**不要搬動已推的 tag**。若 run 紅但 registry 已有 1.5.0 → 視為成功，另開 PR 調 `cache-to`。
5. 回滾：什麼都不用做；未被 compose 引用的新 tag 無害（刪 tag 屬破壞性，除非要求不做）。
6. 建議：映像推出後，在本機用 `IAM_DEBUG_FULL_PERMISSIONS=1` 起一次容器打 `GET /employee-access/permissions/{userId}` 做冒煙（比照 PR #24），這一步不碰開發環境 KurrentDB。

### Phase 4　建立 projection　[共用：KurrentDB 寫入]
前置：Phase 3 已有映像；用 §1.2 的方式 B（或 A）。順序放在換映像之前：新服務一起來，反查候選人就完整；舊服務不讀這兩支，所以先建沒有副作用。
1. 先確認不存在（列表指令見 §1.2），再執行建立指令。
2. 驗證：
   ```bash
   curl -s -u <kdb-user>:<kdb-password> http://<dev-host>:2113/projections/continuous \
     | jq -r '.projections[]|select(.name|startswith("IAM_"))|[.name,.status,.progress,.version]|@tsv'
   ```
   期望四列全 Running；`IAM_GetPermissions` 仍是 version 6、`IAM_PermissionHolders` 仍是 0（證明沒動到既有兩支）。`IAM_RoleHolders` 會處理 383 筆事件後到 100%。再跑一次 `postdeploy-compare.py`（舊服務仍在跑，應是 353 筆「== BEFORE only」＋58 筆「== BEFORE and == EXPECT」，0 筆 OTHER，exit 0）。
3. 未實測的點：`fromStreams(["$ce-IAMRole"])` 指向尚不存在的 stream 時 KurrentDB 26.1 的行為，預期維持 Running。若出現 Faulted，直接刪掉這支（只會刪它自己的 `IAM_GetRoles-all`），等第一個角色建立後再建。
4. 回滾（只動這兩支，不影響既有兩支與服務）：
   ```bash
   for n in IAM_GetRoles IAM_RoleHolders; do
     curl -s -u <kdb-user>:<kdb-password> -d{} "http://<dev-host>:2113/projection/$n/command/disable"
     curl -s -u <kdb-user>:<kdb-password> -X DELETE -H 'Content-Length:0' \
       "http://<dev-host>:2113/projection/$n?deleteStateStream=true&deleteCheckpointStream=true&deleteEmittedStreams=true"
   done
   ```
5. **不要**對 `IAM_GetPermissions`／`IAM_PermissionHolders` 做任何 disable／delete／重建。

### Phase 5　Deployment repo 改 tag　[共用：push]
在乾淨的 clone 或 worktree 操作最安全（本機 Deployment 有 `LocalBuildCommon.yaml` 修改與多個含祕密的未追蹤檔）。
```bash
cd <workspace>/Deployment
/usr/bin/git pull --ff-only                       # 先追上 origin/main 的 5 個 commit
# 只改 DevCommon.yaml 的 iam-context 這一行：1.4.0 -> 1.5.0（單點編輯）
docker compose -f DevCommon.yaml config -q        # -q：只驗證，不把內嵌祕密印到終端
/usr/bin/git diff --stat                          # 預期 DevCommon.yaml 1 行
/usr/bin/git add DevCommon.yaml && /usr/bin/git commit -m "[UPDATE] update iam-context 1.5.0"
/usr/bin/git push origin main
```
注意：不要碰 `Common.yaml`（正式環境，仍是 1.4.0）；不要輸出 `docker compose config` 的完整內容；不要用 `git add -A`。
回滾：revert 該 commit（新 commit），不改寫歷史。

### Phase 6　開發主機換映像　[共用：服務重啟，會短暫中斷]
前置（唯讀，建議先確認；我沒被允許在遠端做 `true` 以外的事，所以下列是**未驗證的假設**）：主機上的部署目錄是不是 `<deploy-home>/MendeskyDeployment`、是不是 git clone、停在哪個分支。
```bash
ssh <deploy-user>@<dev-host> 'cd <deploy-home>/MendeskyDeployment && /usr/bin/git rev-parse --abbrev-ref HEAD && /usr/bin/git status -sb | head -5 && docker compose -f DevCommon.yaml ps iam-context'
ssh <deploy-user>@<dev-host> 'docker inspect --format "{{.Config.Image}} {{.Image}}" $(docker compose -f <deploy-home>/MendeskyDeployment/DevCommon.yaml ps -q iam-context)'
```
記下目前映像 digest（registry 上的 1.4.0 digest 是 `sha256:a4897a5a84fa22ab44ff191c12c9c0f1d4bdd646b02220dfa67e7d6d79300192`），作為回滾依據。
執行（只重建 iam-context，不動其他服務）：
```bash
ssh <deploy-user>@<dev-host> 'cd <deploy-home>/MendeskyDeployment && /usr/bin/git pull --ff-only \
  && docker compose -f DevCommon.yaml pull iam-context \
  && docker compose -f DevCommon.yaml up -d --no-deps iam-context'
```
影響：iam-context 容器重建，HTTP 24202／gRPC 24203 約數秒到十數秒不可用；其他 context 經 gRPC 查權限的請求在此期間失敗（`aborted`／連線錯誤），消費端 60 秒快取只能擋住已快取的使用者。選在低使用時段，並先通知 AuditContext、OpportunityContext 等消費端的維護者。
驗證（依序）：
1. `docker compose -f DevCommon.yaml ps iam-context` 為 running；`docker logs --tail 50` 沒有 `Refusing to start`（缺 token）、沒有 `IAM DEBUG MODE`。
2. 在本機執行（只 GET）：
   ```bash
   cd <scratch>/preflight-2026-10-01
   python3 postdeploy-compare.py
   ```
   判讀：任何 `503` 或 `OTHER` → 立即回滾（Phase 6 回滾），先查是哪個員工；`503` 代表那位員工或其角色 stream 有未登記型別／無法解碼的事件（規格「失敗路徑」），目前掃描預期為零。
   - 若 B1 選 (a)：預期 353 筆「== EXPECT only」、58 筆「unchanged」，0 筆 OTHER。
   - 若 B1 選 (b)：預期 411 筆都等於部署前（把 `--expect` 指到修正後的模擬結果）。
3. 用一個消費端實際走一次權限檢查（例如以 AuditContext 或 OpportunityContext 的測試帳號呼叫一個受保護 endpoint），確認 gRPC 路徑 OK（本次檢查沒有碰 gRPC）。
4. 延遲：heaviest user 員工 E 的 GET 與部署前 41–49 ms 相比不應明顯變差（新版每次重播整條 stream 並讀引用角色的 stream）。
5. 觀察 15 到 30 分鐘 iam-context 日誌。
6. **驗證完成前，不要呼叫任何寫入 API**（grant／revoke／建立角色）。新版允許撤銷「只來自角色」的權限、會寫入事件，換回 1.4.0 後這些撤銷不會被舊版讀取語意還原。

回滾：把 DevCommon.yaml 的 tag 改回 `1.4.0`（revert Phase 5 的 commit 並 push），主機上 `git pull --ff-only && docker compose -f DevCommon.yaml up -d --no-deps iam-context`。若主機尚未 pull，可在主機上直接把該映像換回 digest 再 up。服務本身啟動時不寫入事件，所以回滾沒有資料還原問題；Phase 4 的兩支新 projection 保留即可（舊版不讀）。

### 共用狀態改動一覽
| 步驟 | 動作 | 影響範圍 | 驗證 | 回滾 |
|---|---|---|---|---|
| P2 | push 分支、開 PR、merge | IAMContext main | `gh pr checks`、`merge-base --is-ancestor` | revert PR |
| P3 | push tag 1.5.0 → registry 新 tag；`latest` 移動 | Artifact Registry | `gcloud artifacts docker tags list` | 不用（無人引用）；刪 tag 需另行同意 |
| P4 | 在開發 KurrentDB 建 2 支 projection（含 8 個 `IAM_GetRoleHolders-*` stream） | KurrentDB | `/projections/continuous` | disable＋delete 這兩支 |
| P5 | Deployment repo 改一行 tag 並 push | Deployment main | `config -q`、`diff --stat` | revert commit |
| P6 | 開發主機 iam-context 重建 | 共用開發環境所有 gRPC 消費端 | `postdeploy-compare.py`、日誌 | tag 改回 1.4.0 後重建 |

---

## 3. 沒有驗證到的事（請不要當成已確認）
- 映像只在本機 arm64 驗證過；CI 的 amd64 建置與測試 target 編譯要靠 PR 的 CI 與打 tag 後的 run。
- 我沒有跑任何 Swift 測試，也沒有用新版 Swift 程式對真實資料解碼；§3c 的「零 503」是型別清單、欄位形狀與 link 可解析性的推論，真正的保證是部署後 `postdeploy-compare.py` 全 200。
- org 層 self-hosted runner 是否在線；GitHub 帳務是否仍有限制。
- 開發主機的部署目錄、git 分支、是否已對 Artifact Registry 登入，以及目前跑的 1.4.0 容器到底是哪個 digest（registry 上 1.4.0 是手動推的，來源未知）。
- 整批重建 `IAM_GetPermissions` 實際會花多久（沒有實測，也不應實測）。
- `fromStreams` 指向尚不存在的 `$ce-IAMRole` 時，26.1 版 projection 的狀態。
- 正式環境（<prod-host>）是否有同樣的雙建檔資料：沒有檢查。
