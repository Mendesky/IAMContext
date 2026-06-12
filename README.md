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
PORT=24202 swift run IAMContextServer
```

注意：

- **必須指名 `IAMContextServer`**——package 內有三個 executable（`IAMContextServer` / `EnrollStaffs` / `RevokeAllPrivileges`），裸 `swift run` 會報錯。
- **`PORT=24202` 是專案約定**（code fallback 是 8080，本機常被 OrbStack 等佔用）。
- 同一個 process 以 ServiceGroup 同時起 **HTTP + gRPC**：

| 服務 | env | 預設 | 約定 |
|------|-----|------|------|
| HTTP API | `PORT` | 8080 | **24202** |
| gRPC `PermissionsService`（跨 context 取權限） | `GRPC_PORT` | **24203** | 24203（不用覆寫；對照 IdentityContext 24200/24201 配對） |
| KurrentDB 連線 | `ESDB_URL` | `kurrent://admin:changeit@localhost:2113?tls=false` | — |

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
