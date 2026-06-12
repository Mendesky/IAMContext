import GRPCCore
import IAMContextShared

/// gRPC server interceptor 強制共享 bearer token（code review 2026-06-12，user 決策：Bearer token，明文）.
///
/// 呼叫端須在 metadata 帶 `authorization: Bearer <token>`（或裸 token），與伺服器設定的 token 相符才放行，
/// 否則回 `UNAUTHENTICATED`。純授權決策委派給 `IAMContextShared.BearerTokenAuth`（可單元測試），本型別只負責
/// 從 grpc metadata 取值與轉錯。
///
/// 傳輸為 plaintext：token 在同網段可被嗅探，僅適用可信內網；跨不可信網段需另加 TLS。
struct BearerTokenServerInterceptor: ServerInterceptor {
    let expectedToken: String

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingServerRequest<Input>,
        context: ServerContext,
        next: @Sendable (
            _ request: StreamingServerRequest<Input>,
            _ context: ServerContext
        ) async throws -> StreamingServerResponse<Output>
    ) async throws -> StreamingServerResponse<Output> {
        let authorizationValues = Array(request.metadata[stringValues: "authorization"])
        switch BearerTokenAuth.decide(authorizationValues: authorizationValues, expectedToken: expectedToken) {
        case .authorized:
            return try await next(request, context)
        case .missing:
            throw RPCError(code: .unauthenticated, message: "missing authorization metadata")
        case .invalid:
            throw RPCError(code: .unauthenticated, message: "invalid token")
        }
    }
}
