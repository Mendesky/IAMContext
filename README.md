# IAMContext

Bootstrapped by **Genesis v0.1.0-phase1k2** from bundle `057e8202-6f1f-4e2c-b821-3b63d931f5df`.

## Layout

| Path | Contents |
|------|----------|
| `Package.swift` | SwiftPM manifest |
| `Sources/{Aggregate}Aggregate/` | One library target per aggregate (`1` total) |
| `Sources/IAMContextShared/` | Cross-aggregate value types (DTOs / enums / typed IDs) |
| `Tests/IAMContextTests/` | Test target (placeholder until business logic lands) |
| `.ai/contexts/IAMContext/` | Adapter + manifest |
| `.ai/contexts/IAMContext/<Aggregate>/` | Per-aggregate business docs (SSOT) |
| `.ai/conventions/api.md` | Cross-aggregate API conventions |

## Aggregates

- **EmployeeAccess** — 7 use cases

**Total**: 1 aggregate(s), 7 use case(s), 1 DTO(s).

## Build

```bash
swift build
swift test    # 需要 localhost KurrentDB（整合測試）
```

## Run

```bash
# 本機開發（明確關閉 gRPC auth；PORT 預設已是 24202，可不設）
IAM_GRPC_AUTH_DISABLED=1 swift run IAMContextServer

# 啟用 gRPC auth（部署/整合）：呼叫端（OC）須帶相同 token
IAM_GRPC_AUTH_TOKEN=<shared-token> swift run IAMContextServer
```

注意：

- **必須指名 `IAMContextServer`**——package 內還有 codegen CLI executable（`permission-gen` / `permission-catalog-gen`），裸 `swift run` 會報錯。
- **`PORT` 預設＝專案約定 `24202`**（前端打 API 也是 24202；原 scaffold 預設 8080 常被 OrbStack 佔用，已改）。要覆寫才設 `PORT=`。
- **gRPC auth 是 fail-closed**（code review 2026-06-12）：`IAM_GRPC_AUTH_TOKEN` 與 `IAM_GRPC_AUTH_DISABLED` 兩者皆未設 → **拒絕啟動**（不讓權威服務在無驗證下意外上線）。本機開發請帶 `IAM_GRPC_AUTH_DISABLED=1`。
- 同一個 process 以 ServiceGroup 同時起 **HTTP + gRPC**：

| 服務 | env | 預設 | 約定 |
|------|-----|------|------|
| HTTP API（前端打這個） | `PORT` | **24202** | 24202（不用覆寫） |
| gRPC `PermissionsService`（跨 context 取權限） | `GRPC_PORT` | **24203** | 24203（不用覆寫；對照 IdentityContext 24200/24201 配對） |
| gRPC bearer token | `IAM_GRPC_AUTH_TOKEN` | —（fail-closed） | 設定即啟用守門；呼叫端 metadata 須帶 `authorization: Bearer <token>` |
| gRPC auth 關閉開關 | `IAM_GRPC_AUTH_DISABLED` | — | `=1` 明確關閉（僅限本機/可信內網，會印 SECURITY WARNING） |
| KurrentDB 連線 | `ESDB_URL` | `kurrent://admin:changeit@localhost:2113?tls=false` | — |

> ⚠️ 傳輸目前是 **plaintext**：bearer token 在不可信網段可被嗅探，僅適用可信內網；跨網段需另加 TLS（後續）。

前置條件：

1. **KurrentDB** 跑在 `localhost:2113`。
2. **GetPermissions projection 已部署**（`projections/IAM_GetPermissionsProjection.js`），否則讀端點永遠 404。

啟動後驗證：

```bash
curl -s http://localhost:24202/employee-access/permissions/<userId>   # HTTP read（200 + 權限陣列）
lsof -iTCP:24203 -sTCP:LISTEN                                          # gRPC 在聽
```

## One-shot tools

```bash
STAFF_DATA=<staff.json 路徑> swift run EnrollStaffs          # 批次匯入員工（重跑已存在的 id 會失敗）
STAFF_DATA=<staff.json 路徑> swift run RevokeAllPrivileges   # 撤除匯入時發的佔位權限（非冪等）
```

## Next steps

Business logic lives in `.ai/contexts/IAMContext/<Aggregate>/`. See `CLAUDE.md` for how to use Claude Code skills (`/usecase`, `/readmodel`, `/api`) to fill in the stubs.
