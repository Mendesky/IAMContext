import DDDKit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import GRPCServiceLifecycle
import HTTPTypes
import Hummingbird
import KurrentDB
import Logging
import OpenAPIHummingbird
import ServiceLifecycle
import EmployeeAccessAggregate

import IAMContextShared

import struct EmployeeAccessAggregate.ApiHandler


@main
@MainActor
struct IAMContextServer {
    static let logger = Logger(label: "IAMContext")

    static func main() async throws {
        let env = ProcessInfo.processInfo.environment

        let router = Router()

        // CORS — must precede AdminTokenMiddleware so OPTIONS preflight is not blocked by auth.
        // Hummingbird 內建版，參數比照 OC（user 決策 2026-07-14：.all 與 OC 一致；安全邊界在 admin token，
        // 不在 origin）。內建版對 throw 出的 4xx/5xx 也會補 CORS header（EditedHTTPError），
        // 瀏覽器讀得到實際狀態碼——先前手寫版/共用 DynamicCORS 版都做不全這點。
        router.addMiddleware {
            CORSMiddleware(
                allowOrigin: .all,
                allowHeaders: [.contentType, .authorization, HTTPField.Name("operatorId")!, HTTPField.Name("userId")!],
                allowMethods: [.get, .post, .put, .delete, .patch, .options]
            )
        }

        // HTTP admin auth (user 決策：方案 a — 管理員共用 token). HTTP 變更端點（grant/revoke/…）改動「授權
        // 權威」本身，缺守門時任何能連到 :24202 的呼叫者都能把任意權限授給自己。對所有非 GET 請求要求
        // Authorization: Bearer <IAM_ADMIN_API_TOKEN>；GET（唯讀 getPermissions）放行。**Fail-closed**（比照 gRPC）：
        //   - IAM_ADMIN_API_TOKEN=<token>   → 啟用管理員 token 守門。
        //   - IAM_ADMIN_API_AUTH_DISABLED=1 → 明確關閉（僅限本機/可信內網開發），會印 SECURITY WARNING。
        //   - 兩者皆未設                     → 拒絕啟動。
        let adminApiToken = env["IAM_ADMIN_API_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        let adminApiAuthDisabled = env["IAM_ADMIN_API_AUTH_DISABLED"] == "1"
        if let adminApiToken {
            router.addMiddleware {
                AdminTokenMiddleware(expectedToken: adminApiToken)
            }
            logger.info("HTTP admin auth: ENABLED (bearer token on mutating endpoints)")
        } else if adminApiAuthDisabled {
            logger.warning("⚠️ SECURITY: HTTP admin auth DISABLED (IAM_ADMIN_API_AUTH_DISABLED=1) — 變更端點對任何能連到 HTTP API 的呼叫者開放，僅限本機/可信內網開發使用")
        } else {
            logger.critical("HTTP admin auth not configured: set IAM_ADMIN_API_TOKEN=<token> (or IAM_ADMIN_API_AUTH_DISABLED=1 for local dev). Refusing to start an unauthenticated permission authority HTTP API.")
            throw IAMContextServerError.adminApiAuthNotConfigured
        }

        let esdbSettings = env["ESDB_URL"]
            ?? "kurrent://admin:changeit@localhost:2113?tls=false"
        let settings: ClientSettings = try esdbSettings.parse()
        let kdbClient = KurrentDBClient(settings: settings)

        let serverURL = URL(string: "/")!

        try EmployeeAccessAggregate.ApiHandler(kdbClient: kdbClient)
            .registerHandlers(on: router, serverURL: serverURL, middlewares: [])

        // TODO(Phase 1.m v2): projection subscription wiring
        //   - Stream naming: Genesis projection JS uses `$ce-<SourceCategoryPrefix><Aggregate>`
        //     (e.g. `$ce-IAMUserAccessProfile`，非 `$ce-UserAccessProfile`)，
        //     prefix 由 ReadModelRenderer 從 contextName 衍生（IAMContext → "IAM"，OpportunityContext → "OC"）。
        //     詳見 docs/decisions.md Phase 1.g ratification 的 SourceCategoryPrefix 規則。
        //   - Create KurrentDB persistent subscription per stream
        //   - Setup EventBus + EventMappers per source aggregate
        //   - Dispatch RecordedEvent via mappers → eventBus → projectors
        //   - Until subscription is wired, read endpoints return empty/notFound
        //     (projection state stays empty without event ingestion).
        //   See OC `OCServer.swift` for production-level pattern with retry/nack.

        // HTTP API port. 預設＝專案約定 24202（與 gRPC 預設 24203 各自對齊自己的約定 port，互不衝突）。
        // 原 scaffold 預設 8080 常被 OrbStack 佔用，已改。
        let portString = ProcessInfo.processInfo.environment["PORT"] ?? "24202"
        let port = Int(portString) ?? 24202
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("0.0.0.0", port: port))
        )

        // Context-to-context entry point (mirrors IdentityContext: HTTP for frontend/external,
        // gRPC for inter-context calls — Identity pairs 24200/24201, IAM pairs PORT/GRPC_PORT).
        let grpcPortString = ProcessInfo.processInfo.environment["GRPC_PORT"] ?? "24203"
        let grpcPort = Int(grpcPortString) ?? 24203

        // gRPC auth (code review 2026-06-12，user 決策：Bearer token). 24203（PermissionsService）是 IAM 對下游
        // 授權的權威來源，無守門時任何能連到 port 的呼叫者都能查任一 user 的權限視圖。**Fail-closed**：
        //   - IAM_GRPC_AUTH_TOKEN=<token>  → 啟用 bearer-token 守門（呼叫端 metadata 須帶 authorization）。
        //   - IAM_GRPC_AUTH_DISABLED=1     → 明確關閉（僅限本機/可信內網開發），會印 SECURITY WARNING。
        //   - 兩者皆未設                    → 拒絕啟動（不讓權威服務在無驗證下意外上線）。
        // 注意：傳輸為 plaintext，token 在不可信網段可被嗅探；跨網段需另加 TLS。
        let grpcAuthToken = env["IAM_GRPC_AUTH_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
        let grpcAuthDisabled = env["IAM_GRPC_AUTH_DISABLED"] == "1"
        var grpcInterceptors: [any ServerInterceptor] = []
        if let grpcAuthToken {
            grpcInterceptors.append(BearerTokenServerInterceptor(expectedToken: grpcAuthToken))
            logger.info("gRPC auth: ENABLED (bearer token)")
        } else if grpcAuthDisabled {
            logger.warning("⚠️ SECURITY: gRPC auth DISABLED (IAM_GRPC_AUTH_DISABLED=1) — 24203 對任何能連到的呼叫者開放，僅限本機/可信內網開發使用")
        } else {
            logger.critical("gRPC auth not configured: set IAM_GRPC_AUTH_TOKEN=<token> (or IAM_GRPC_AUTH_DISABLED=1 for local dev). Refusing to start an unauthenticated permission authority on \(grpcPort).")
            throw IAMContextServerError.grpcAuthNotConfigured
        }

        let grpcServer = GRPCServer(transport: .http2NIOPosix(
            address: .ipv4(host: "0.0.0.0", port: grpcPort),
            transportSecurity: .plaintext
          ), services: [
            PermissionsService(kdbClient: kdbClient)
          ], interceptors: grpcInterceptors)

        logger.info("starting IAMContextServer on 0.0.0.0:\(port) (HTTP) / 0.0.0.0:\(grpcPort) (gRPC)")
        let serviceGroup = ServiceGroup(services: [app, grpcServer], logger: logger)
        try await serviceGroup.run()
    }
}

enum IAMContextServerError: Error, CustomStringConvertible {
    case grpcAuthNotConfigured
    case adminApiAuthNotConfigured

    var description: String {
        switch self {
        case .grpcAuthNotConfigured:
            return "gRPC auth not configured (set IAM_GRPC_AUTH_TOKEN, or IAM_GRPC_AUTH_DISABLED=1 for local dev)"
        case .adminApiAuthNotConfigured:
            return "HTTP admin auth not configured (set IAM_ADMIN_API_TOKEN, or IAM_ADMIN_API_AUTH_DISABLED=1 for local dev)"
        }
    }
}
