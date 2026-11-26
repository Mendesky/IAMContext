# 授權範圍 API 對接說明（console、OC）

設計：`docs/discussions/2026-11-25-scoped-permission-grant.md`（分支 `docs/scoped-permission-grant`）。

## 什麼是範圍化的權限

權限清單（各 context 的 `*.permissions.yaml`）上標了 `grantScopeKinds` 的權限，授權時一定要帶範圍：

```yaml
permissions:
  - slot: ManagerDashboard
    operationId: viewQuotingCases
    description: "..."
    grantScopeKinds: [company, firms, departments, ownFirm, ownDepartment]
```

沒標的權限照舊，授權時不能帶範圍。目前權限清單裡還沒有範圍化的權限，所以這一版上線後行為跟以前一樣。

## 範圍的格式

```json
{ "kind": "company" }
{ "kind": "firms", "firms": ["47575385", "82576039"] }
{ "kind": "departments", "departments": [{ "firm": "47575385", "department": "審1" }] }
{ "kind": "ownFirm" }
{ "kind": "ownDepartment" }
```

- 一個權限可以有多項範圍，取聯集。
- 所別一律統編（8 碼半形數字，IAM 會檢查格式；不比對 StaffContext 的所別清單）；組在同一所內才唯一，所以帶（所統編, 組名）。
- `ownFirm`／`ownDepartment` 只是標記，由呼叫端在查詢當下用 StaffContext 名冊解析（不要用 IAM 員工身上的 firm／department，那份沒有跟名冊同步）。
- 讀取時遇到不認得的 `kind`（日後新增的種類）請略過那一項，不要整筆失敗。

## 寫入（要管理員 token）

| 端點 | 說明 |
|---|---|
| `POST /employee-access/{employeeAccessId}/grant-privilege` | body 多一個選填的 `grantScopes`：`{ "<權限>": [範圍, …] }`。範圍化的權限一定要帶、至少一項；不是範圍化的權限不能帶；key 一定要在 `permissions` 裡 |
| `POST /employee-access/{employeeAccessId}/change-grant-scope` | body：`{ "userId", "permission", "grantScopes": [範圍, …] }`。整組換掉。權限要是直接持有、目前有效、而且是範圍化的權限。也用來幫「權限標成範圍化之前就持有、還沒有範圍」的人補範圍。**新版 IAM 上線後先不要用，等確定不退版再開始用（見下方「事件與相容性」）** |

已持有的權限再 `grant-privilege` 一次會回 `permissionAlreadyExists`。console 的批次授權現在把它記成「略過」：遇到「已持有、但這次選了不同範圍」時，要改走 `change-grant-scope`，不能默默略過。

新的錯誤碼（都是 422）：

| 錯誤碼 | 意思 |
|---|---|
| `grantScopeRequired` | 範圍化的權限沒帶範圍，或範圍是空的 |
| `grantScopeKindNotAllowed` | 範圍種類不在這個權限允許的清單裡 |
| `grantScopeNotApplicable` | 不是範圍化的權限卻帶了範圍；`grantScopes` 裡有這次沒授予的權限；改範圍的權限不是範圍化的權限 |
| `grantScopeInvalid` | 範圍內容不合法（種類不認得、指定所是空的、所別不是 8 碼統編、指定組缺組名、`company`／`own*` 帶了清單） |
| `grantScopeUnchanged` | 改範圍時新範圍跟現在一樣（比對前會去掉空白、去重、排序） |
| `roleContainsScopedPermission` | 指派的角色裡有範圍化的權限（角色不能帶範圍） |
| `scopedPermissionNotAllowed`（角色 API） | 不能把範圍化的權限加進角色 |

## 讀取

| 端點 | 說明 |
|---|---|
| `GET /employee-access/permissions/{userId}/grant-scopes` | 回 `[{ "permission", "grantScopes": [範圍, …] }]`，只列有範圍的權限、依權限名稱排序。尚未建檔回 404 |
| gRPC `IAMContext.PermissionsService/GetPermissionGrantScopes` | 同上；尚未建檔回空清單（同 `GetPermissions`）。proto 見 `proto/PermissionsService.proto`；只有要讀範圍的服務需要更新 proto 副本 |
| `GET /employee-access/permissions/{userId}`、gRPC `GetPermissions` | **不變**，仍只回權限名稱。範圍不會編進權限名稱 |

`IAM_DEBUG_FULL_PERMISSIONS=1`（本機、測試環境用，正式不開）時，範圍查詢對權限清單上每個範圍化的權限都回 `company`（gRPC 帶 `x-iam-debug: 1`），**不管這個權限允許哪些種類**。消費端對每個範圍化權限都要能處理 `company`（當成全部涵蓋），不要假設拿到的種類一定在允許清單裡。

## 事件與相容性

- 授權時的範圍存在 `PrivilegeGranted` 的選填欄位 `grantScopes`。舊版 IAM（1.8.0）讀到會略過這個欄位（權限照常有效、只是看不到範圍），只用授權帶範圍時可以退版。
- 改範圍是新的事件型別 `PrivilegeScopeChanged { userId, permission, grantScopes }`，如實記下「改範圍」。舊版 IAM 讀到不認得的事件型別會 fail-closed（那個人的查權限整個失敗），所以：
  - 新版上線後先不要呼叫 change-grant-scope；等新版穩定、確定不會退回 1.8.0 再開始用。第一階段看板只需要授權帶範圍。
  - `IAM_GetPermissions` 投影要加上 `PrivilegeScopeChanged`：停用 → 換查詢 → 啟用（`PUT /projection/IAM_GetPermissions/query?type=js&emit=true`），不要刪除重建（重建期間全員 403）。這個型別上線前沒有任何歷史事件，換查詢不用 reset。
  - IAM 的 `GetPermissions` 讀取模型也要認得它（no-op），否則讀取模型重播會中止在這一筆。

## proto 重產

`Sources/Generated` 用 protoc-gen-swift 1.37.0、protoc-gen-grpc-swift-2（grpc-swift-protobuf 2.4.0，grpc-swift-2 2.4.1）產生；用這組版本重產既有的 proto 會跟 main 逐字相同。
