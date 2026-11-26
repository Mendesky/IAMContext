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
    /// 角色定義出埠（階段二）。與 HTTP ApiHandler 共用同一實例（IAMContextServer 組裝）。
    let roleDirectory: RoleDirectory
    let debugConfig: DebugConfig

    init(kdbClient: KurrentDBClient, roleDirectory: RoleDirectory, debugConfig: DebugConfig = .fromEnvironment()) {
        self.kdbClient = kdbClient
        self.roleDirectory = roleDirectory
        self.debugConfig = debugConfig
    }

    func getPermissions(request: ServerRequest<IAMContext_GetPermissionsRequest>, context: ServerContext) async throws -> ServerResponse<IAMContext_GetPermissionsResponse> {
        do {
            // Resolve debug override once: if IAM_DEBUG_FULL_PERMISSIONS=1, pass the full
            // catalog rawValues so the service skips per-user lookup.
            let override: [String]? = debugConfig.fullPermissions
                ? Array(PermissionCatalog.allRawValues).sorted()
                : nil
            let service = GetPermissionsApplicationService(kdbClient: kdbClient, roleDirectory: roleDirectory, debugOverridePermissions: override)
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

    /// 權限＋範圍查詢（docs/discussions/2026-11-25-scoped-permission-grant.md D14），規則同 HTTP getPermissionGrantScopes。
    /// 尚未建檔回空清單（同 getPermissions）；IAM_DEBUG_FULL_PERMISSIONS 開啟時每個範圍化權限都回 company，並帶 x-iam-debug。
    func getPermissionGrantScopes(request: ServerRequest<IAMContext_GetPermissionGrantScopesRequest>, context: ServerContext) async throws -> ServerResponse<IAMContext_GetPermissionGrantScopesResponse> {
        do {
            let override: [PermissionGrantScopes]? = debugConfig.fullPermissions
                ? GetPermissionGrantScopesApplicationService.debugOverride(scopedPermissions: PermissionCatalog.grantScopeKinds.keys)
                : nil
            let service = GetPermissionGrantScopesApplicationService(kdbClient: kdbClient, roleDirectory: roleDirectory, debugOverride: override)
            let items = try await service.execute(input: .init(userId: request.message.userID))
            let message = IAMContext_GetPermissionGrantScopesResponse.with { $0.permissions = items.map(Self.message(from:)) }
            if debugConfig.fullPermissions {
                var metadata = Metadata()
                metadata.addString("1", forKey: "x-iam-debug")
                return .init(message: message, metadata: metadata)
            }
            return .init(message: message)
        } catch let error as ContextError<EmployeeAccessQueryError> where error.error == .notFound {
            return .init(message: .init())
        } catch {
            return .init(error: .init(status: .init(code: .aborted, message: "getPermissionGrantScopes failed. error: \(error)"))!)
        }
    }

    static func message(from item: PermissionGrantScopes) -> IAMContext_PermissionGrantScopes {
        .with { message in
            message.permission = item.permission
            message.grantScopes = item.grantScopes.map { scope in
                .with { grantScope in
                    grantScope.kind = scope.kind
                    grantScope.firms = scope.firms ?? []
                    grantScope.departments = (scope.departments ?? []).map { department in
                        .with {
                            $0.firm = department.firm
                            $0.department = department.department
                        }
                    }
                }
            }
        }
    }
}
