# gRPC PermissionsService — auth 契約（消費端必讀）

> 來源：code review 2026-06-12 高風險修復（user 決策：Bearer token，明文）。
> 伺服器端已實作並驗證（見本 repo `Sources/IAMContextServer/`）；本檔描述**呼叫端（OC 等）必須滿足的契約**。

## 契約

IAM 的 `PermissionsService`（gRPC，預設 `:24203`）現在**強制 bearer token**。每個 RPC 的 metadata 必須帶：

```
authorization: Bearer <shared-token>
```

- 缺 metadata → `UNAUTHENTICATED`（"missing authorization metadata"）。
- token 不符 → `UNAUTHENTICATED`（"invalid token"）。
- scheme 大小寫不敏感；裸 token（不帶 `Bearer ` 前綴）也接受。
- 比較為常數時間（防 timing oracle）。

`<shared-token>` 由部署協調：IAM 端設 `IAM_GRPC_AUTH_TOKEN`，呼叫端設相同值（建議各自走 env / secret manager，**勿** hardcode）。

> ⚠️ 傳輸是 **plaintext**：token 在不可信網段可被嗅探，僅適用可信內網；跨網段需另加 TLS（後續）。

## 伺服器端 fail-closed 行為（本 repo）

| env | 行為 |
|-----|------|
| `IAM_GRPC_AUTH_TOKEN=<token>` | 啟用守門 |
| `IAM_GRPC_AUTH_DISABLED=1` | 明確關閉（本機/可信內網開發），印 SECURITY WARNING |
| 兩者皆未設 | **拒絕啟動** |

## OC 端要改什麼（交接給負責 IAM 權限 client 的 agent）

OC 的 `OpportunityContext/Sources/IAMContextClient/Adapter/GRPCClient.swift`（`IAMContextGRPCClient`）目前建 `GRPCClient` 時**沒帶任何 metadata**，IAM 啟用守門後會被擋。需要加一個 client interceptor 注入 `authorization`，並把 token 從 env 帶入。

grpc-swift-2 已確認可用 API：`GRPCClient(transport:, interceptors: [any ClientInterceptor])` + `Metadata.replaceOrAddString(_:forKey:)`。

建議實作（新檔，例如 `IAMContextClient/Adapter/BearerTokenClientInterceptor.swift`）：

```swift
import GRPCCore

struct BearerTokenClientInterceptor: ClientInterceptor {
    let token: String

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        // ⚠️ `next` 不是 @Sendable —— grpc-swift-2 的 ClientInterceptor.intercept 宣告的 next 是「純」closure
        //    （見 GRPCCore/Call/Client/ClientInterceptor.swift）。加 @Sendable 會讓本方法不符合 protocol 需求、編不過。
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.replaceOrAddString("Bearer \(token)", forKey: "authorization")
        return try await next(request, context)
    }
}
```

> 簽章校正（2026-06-22，EPC 回報實測）：`next` 早先誤標 `@Sendable`，照抄會編不過。已對照 grpc-swift-2 原始碼
> `Sources/GRPCCore/Call/Client/ClientInterceptor.swift`（`next` 為純 closure）更正。

然後在 `IAMContextGRPCClient` 建 client 時掛上（token 從 init 傳入、最終由 OC composition root 從 env 帶）：

```swift
// IAMContextGRPCClient 增加 let token: String?（init 帶入；nil = 不附 token，給本機對 DISABLED 的 IAM）
let interceptors: [any ClientInterceptor] = token.map { [BearerTokenClientInterceptor(token: $0)] } ?? []
let client = try GRPCClient<HTTP2ClientTransport.Posix>(
    transport: .init(target: .dns(host: host, port: port), transportSecurity: transportSecurity),
    interceptors: interceptors
)
```

要點：
- token `Optional`：本機對「`IAM_GRPC_AUTH_DISABLED=1` 的 IAM」可不帶；對啟用守門的 IAM 必帶。
- IAM 回 `UNAUTHENTICATED` 時，`permissions(forUserId:)` 會 throw → PermissionMiddleware 既有的 fail-closed（502）行為涵蓋，不需另外處理。

## Rollout 順序（避免互相打斷）

1. （現況）IAM 端先用 `IAM_GRPC_AUTH_DISABLED=1` 跑 → OC 不帶 token 仍可運作。
2. OC 端依上節加好 interceptor + token env（未設 token 時走 nil＝不附）。
3. 協調好 `<shared-token>` 後，IAM 改設 `IAM_GRPC_AUTH_TOKEN`、OC 設相同值 → 同時切到守門開啟。
4. 移除 `IAM_GRPC_AUTH_DISABLED=1`。
