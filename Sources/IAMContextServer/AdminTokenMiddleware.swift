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
///   - `readOnlyPostPaths` 白名單（唯讀但因輸入是清單而必須用 POST 的查詢端點，見下）
///
/// 純授權決策委派 `IAMContextShared.BearerTokenAuth`（常數時間比對，與 gRPC 同一套）。
/// 明文傳輸：token 在同網段可被嗅探，僅適用可信內網；跨不可信網段需另加 TLS。
struct AdminTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    /// 唯讀但必須用 POST 的查詢端點白名單。
    ///
    /// `scope-check` 是唯讀判斷（回「這些 userId 之中誰屬於該所該組」），輸入是 userId 清單、
    /// 不適合塞 query string，故用 POST。它不改動任何授權資料，要求 admin token 反而會逼
    /// 呼叫端（OpportunityContext）持有可 grant/revoke 任意權限的 token，權限過大。
    ///
    /// 暴露面評估（2026-09-03 決策）：既有的唯讀 GET `permission-holders?permission=&firm=&department=`
    /// 已能回答同樣的組織歸屬問題、且額外洩露權限持有狀況，故放行 scope-check 不新增暴露類別。
    /// 「IAM 唯讀面整體是否該加認證」是更大的獨立議題，不在此處理。
    static var readOnlyPostPaths: Set<String> { ["/employee-access/scope-check"] }

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
        // 白名單：唯讀但用 POST 的查詢端點（見 readOnlyPostPaths 註解）。
        if request.method == .post, Self.readOnlyPostPaths.contains(request.uri.path) {
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
