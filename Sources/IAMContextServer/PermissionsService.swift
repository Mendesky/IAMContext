//
//  PermissionsService.swift
//  IAMContext
//
//  gRPC adapter for the GetPermissions use-case — the cross-context entry point other
//  contexts' PermissionMiddleware calls (mirrors IdentityContext's AuthCodeService pattern:
//  REST stays for frontend/external traffic, gRPC serves context-to-context calls).
//
import Foundation
import GRPCCore
import Generated
import IAMPermissionCatalog
import KurrentDB
import EmployeeAccessAggregate
import IAMContextShared

actor PermissionsService: IAMContext_PermissionsService.ServiceProtocol {

    let kdbClient: KurrentDBClient
    let debugConfig: DebugConfig

    init(kdbClient: KurrentDBClient, debugConfig: DebugConfig = .fromEnvironment()) {
        self.kdbClient = kdbClient
        self.debugConfig = debugConfig
    }

    func getPermissions(request: ServerRequest<IAMContext_GetPermissionsRequest>, context: ServerContext) async throws -> ServerResponse<IAMContext_GetPermissionsResponse> {
        do {
            // Resolve debug override once: if IAM_DEBUG_FULL_PERMISSIONS=1, pass the full
            // catalog rawValues so the service skips per-user lookup.
            let override: [String]? = debugConfig.fullPermissions
                ? Array(PermissionCatalog.allRawValues).sorted()
                : nil
            let service = GetPermissionsApplicationService(kdbClient: kdbClient, debugOverridePermissions: override)
            let permissions = try await service.execute(input: .init(userId: request.message.userID))
            if debugConfig.fullPermissions {
                var metadata = Metadata()
                metadata.addString("1", forKey: "x-iam-debug")
                return .init(message: .with { $0.permissions = permissions }, metadata: metadata)
            }
            return .init(message: .with { $0.permissions = permissions })
        } catch let error as ContextError<EmployeeAccessQueryError> where error.error == .notFound {
            // 尚未建檔的員工（無 employee-access aggregate）＝零權限：回成功、空權限清單，
            // 讓消費端能乾淨判定 deny→403，而不是把 gRPC .notFound 誤讀成 fail-closed 502。
            // 只有「aggregate/read-model 不存在」轉空清單；其他真正的錯誤走下方 generic catch。
            return .init(message: .with { response in
                response.permissions = []
            })
        } catch {
            return .init(error: .init(status: .init(code: .aborted, message: "getPermissions failed. error: \(error)"))!)
        }
    }

}
