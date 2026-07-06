import HTTPTypes
import Hummingbird
import IAMContextShared

/// HTTP 端管理員 token 守門（對齊 gRPC 的 `BearerTokenServerInterceptor`；user 決策：方案 a）。
///
/// IAM 的 HTTP 變更端點（grant-privilege / revoke-privilege / assign-roles / revoke-roles /
/// promote-user / transfer-department / create-user-access-profile）會改動「授權權威」本身；
/// 缺守門時任何能連到 `:24202` 的呼叫者都能把任意權限授給自己。
///
/// 本中介對**所有非 GET 請求**（即上述變更端點）要求 `Authorization: Bearer <IAM_ADMIN_API_TOKEN>`
/// （或裸 token），不符回 401。放行：
///   - `GET`（唯讀，如 getPermissions；前端登入時帶 user token 打這個）
///   - `OPTIONS`（CORS preflight）
///
/// 純授權決策委派 `IAMContextShared.BearerTokenAuth`（常數時間比對，與 gRPC 同一套）。
/// 明文傳輸：token 在同網段可被嗅探，僅適用可信內網；跨不可信網段需另加 TLS。
struct AdminTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let expectedToken: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        // 唯讀 GET 與 CORS preflight 放行；其餘（變更端點）要管理員 token。
        if request.method == .get || request.method == .options {
            return try await next(request, context)
        }
        let authorizationValues = request.headers[values: .authorization]
        switch BearerTokenAuth.decide(authorizationValues: authorizationValues, expectedToken: expectedToken) {
        case .authorized:
            return try await next(request, context)
        case .missing, .invalid:
            return Response(status: .unauthorized)
        }
    }
}
