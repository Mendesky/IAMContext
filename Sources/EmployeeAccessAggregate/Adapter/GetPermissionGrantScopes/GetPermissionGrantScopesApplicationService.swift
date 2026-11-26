import Foundation
import KurrentDB
import IAMContextShared

package struct GetPermissionGrantScopesApplicationServiceInput {
    package let userId: String

    package init(userId: String) {
        self.userId = userId
    }
}

/// 一個範圍化權限與它的授權範圍（查詢回傳用）。
package struct PermissionGrantScopes: Sendable, Equatable {
    package let permission: String
    package let grantScopes: [GrantScope]

    package init(permission: String, grantScopes: [GrantScope]) {
        self.permission = permission
        self.grantScopes = grantScopes
    }
}

/// 「權限＋範圍」查詢（2026-11-25 設計文件 D14）。只列有範圍的權限，依權限名稱排序。
/// - 不認得的範圍種類只略過那一項（D9）；一項都不剩的權限不列（等同沒有範圍，D10）。
/// - 「本人的所／組」原樣回標記，由呼叫端用 StaffContext 名冊解析（D11）。
/// - 尚未建檔丟 `EmployeeAccessQueryError.notFound`（同 getPermissions）。
package struct GetPermissionGrantScopesApplicationService: ApplicationService {
    package typealias Input = GetPermissionGrantScopesApplicationServiceInput
    package typealias Output = [PermissionGrantScopes]

    private let kdbClient: KurrentDBClient
    private let roleDirectory: RoleDirectory

    /// IAM_DEBUG_FULL_PERMISSIONS 開啟時由 IAMContextServer 帶入：權限清單上每個範圍化的權限都回 company，
    /// 不讀個人資料（跟 getPermissions 的 debugOverridePermissions 同一個開關）。
    package let debugOverride: [PermissionGrantScopes]?

    package init(kdbClient: KurrentDBClient, roleDirectory: RoleDirectory, debugOverride: [PermissionGrantScopes]? = nil) {
        self.kdbClient = kdbClient
        self.roleDirectory = roleDirectory
        self.debugOverride = debugOverride
    }

    package func execute(input: Input) async throws -> Output {
        if let debugOverride {
            return debugOverride
        }
        let timeline = PermissionTimelineService(kdbClient: kdbClient, roleDirectory: roleDirectory)
        guard let scopes = try await timeline.effectiveGrantScopes(userId: input.userId) else {
            throw ContextError<EmployeeAccessQueryError>(
                error: .notFound,
                in: .struct(GetPermissionGrantScopesApplicationService.self, function: #function),
                message: "employee event stream not found for \(input.userId)"
            )
        }
        return Self.listing(scopes)
    }

    /// 略過不認得的種類、去掉一項都不剩的權限，依權限名稱排序。
    package static func listing(_ scopes: [String: [GrantScope]]) -> [PermissionGrantScopes] {
        scopes.compactMap { permission, grantScopes in
            let known = grantScopes.filter { $0.knownKind != nil }
            return known.isEmpty ? nil : PermissionGrantScopes(permission: permission, grantScopes: known)
        }
        .sorted { $0.permission < $1.permission }
    }

    /// IAM_DEBUG_FULL_PERMISSIONS 用：每個範圍化的權限都回 company。
    package static func debugOverride(scopedPermissions: some Sequence<String>) -> [PermissionGrantScopes] {
        Set(scopedPermissions).sorted().map { PermissionGrantScopes(permission: $0, grantScopes: [.company]) }
    }
}
