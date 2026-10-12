import Foundation
import KurrentDB
import IAMContextShared

package struct GetPermissionsApplicationServiceInput {
    package let userId: String

    package init(userId: String) {
        self.userId = userId
    }
}

package struct GetPermissionsApplicationService: ApplicationService {
    package typealias Input = GetPermissionsApplicationServiceInput
    package typealias Output = [String]

    private let kdbClient: KurrentDBClient
    /// 角色定義出埠：提供時間軸重播所需的角色歷史。
    private let roleDirectory: RoleDirectory

    /// When non-nil, the service bypasses the per-user read-model lookup and returns this
    /// fixed set instead.  Used by IAMContextServer to implement IAM_DEBUG_FULL_PERMISSIONS:
    /// the server resolves PermissionCatalog.allRawValues (from IAMPermissionCatalog target)
    /// and passes it here so this target stays free of that dependency.
    package let debugOverridePermissions: [String]?

    package init(kdbClient: KurrentDBClient, roleDirectory: RoleDirectory, debugOverridePermissions: [String]? = nil) {
        self.kdbClient = kdbClient
        self.roleDirectory = roleDirectory
        self.debugOverridePermissions = debugOverridePermissions
    }

    package func execute(input: Input) async throws -> Output {
        // IAM_DEBUG_FULL_PERMISSIONS=1 — skip per-user lookup, return the injected catalog.
        // getPermissionHolders is intentionally not affected.
        if let overrides = debugOverridePermissions {
            return overrides
        }

        // 有效權限 = 員工事件與其持有過的角色事件依全域位置重播的結果（D2、D3）。
        let timeline = PermissionTimelineService(kdbClient: kdbClient, roleDirectory: roleDirectory)
        guard let permissions = try await timeline.effectivePermissions(userId: input.userId) else {
            throw ContextError<EmployeeAccessQueryError>(
                error: .notFound,
                in: .struct(GetPermissionsApplicationService.self, function: #function),
                message: "employee event stream not found for \(input.userId)"
            )
        }
        return Array(permissions)
    }
}
