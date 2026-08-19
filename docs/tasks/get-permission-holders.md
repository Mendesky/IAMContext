# GetPermissionHolders — 實作說明

## 需求

OpportunityContext 案件建檔時，需要知道「持有某 per-office 分配權限（例如 `OpportunityContext.Handover.AllocateForTaipei`）的人是誰」，以便自動加為案件檢視者。IAM 新增反查能力：給定一個 permission rawValue，回傳目前所有持有者的 userId 清單。

## API Contract

```
GET /employee-access/permission-holders?permission=<rawValue>
Authorization: 無需額外 token（GET 請求由 AdminTokenMiddleware 自動放行）
```

**Response 200:**
```json
["userId-A", "userId-B"]
```

無人持有時：
```json
[]
```

**Response 503:** `{ "error": "serviceUnavailable" }`

## 架構決策

**Projection 方案**（選擇）vs Request-time scan（放棄）：

- Projection 方案：建 `IAM_PermissionHolders-<rawValue>` per-permission stream，與 GetPermissions 的 `IAM_GetPermissions-<userId>` 完全對稱。正確性：stream 只含涉及該 permission 的事件，重播後得當前持有者清單。
- Request-time scan 放棄原因：需讀所有 userId stream，O(全員工) 次 KDB 請求，scale 差。

## KDB Projection 部署（需操作者手動執行）

新增 projection 檔：`projections/IAM_PermissionHoldersProjection.js`

KDB projection 名稱：`IAM_PermissionHolders`

部署指令（同既有 IAM_GetPermissions projection）：
```bash
bash scripts/projection.sh
# 或指定遠端 KDB：
KDB_HOST=<host> KDB_PORT=<port> bash scripts/projection.sh
```

`scripts/projection.sh` 自動掃 `projections/` 目錄下所有 `*Projection.js`，會一併部署 `IAM_PermissionHoldersProjection.js`。

## 新增檔案清單

| 檔案 | 說明 |
|---|---|
| `Sources/EmployeeAccessAggregate/projection-model.yaml` | 加入 `GetPermissionHolders` 讀模型定義，觸發 ModelGeneratorPlugin 生成 `GetPermissionHoldersProjectorProtocol` |
| `Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissionHolders/PermissionHoldersReadModel.swift` | 讀模型：`permission` + `userIds: [String]` |
| `Sources/EmployeeAccessAggregate/Usecase/Projector/GetPermissionHolders/GetPermissionHoldersPresenter.swift` | Projector：遵循 generated protocol，實作 grant/revoke 邏輯 |
| `Sources/EmployeeAccessAggregate/Adapter/GetPermissionHolders/GetPermissionHoldersApplicationService.swift` | Application service：無人持有回 `[]` 而非 throw |
| `projections/IAM_PermissionHoldersProjection.js` | KDB Continuous Projection（需手動部署） |
| `Tests/IAMContextTests/GetPermissionHoldersIntegrationTests.swift` | 整合測試（2 個測試，happy path 需 projection 部署） |

## 修改檔案清單

| 檔案 | 修改內容 |
|---|---|
| `Sources/EmployeeAccessAggregate/openapi.yaml` | 新增 `GET /employee-access/permission-holders` 端點 + `permission` query parameter 定義 |
| `Sources/EmployeeAccessAggregate/Adapter/ApiHandler.swift` | 實作 `getPermissionHolders()` handler method |

## 不受影響的既有功能

- `GET /employee-access/permissions/{userId}` 行為完全不變
- gRPC `PermissionsService` 不變
- permission catalog yaml 不變

## 測試狀態

- `unknown_permission_returns_empty_array`：PASS（不需 projection 部署）
- `grant_then_revoke_returns_only_active_holders`：需要 `bash scripts/projection.sh` 部署後才能通過
