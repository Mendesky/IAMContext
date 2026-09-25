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
    /// 角色定義出埠（階段二）：把 read model 內的 roleId 解析成權限集合並與直接授權聯集。
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

        // /presenter-fill: 透過 GetPermissionsPresenter（projector）抓 read model，map readModel.permissions → Output。
        let presenter = GetPermissionsPresenter(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
        guard let readModel = try await presenter.execute(input: .init(userId: input.userId))?.readModel else {
            throw ContextError<EmployeeAccessQueryError>(
                error: .notFound,
                in: .struct(GetPermissionsApplicationService.self, function: #function),
                message: "read model not found for \(input.userId)"
            )
        }
        // 階段二：有效權限 = 直接授權 ∪ ⋃ 角色權限。解析不到／已刪除的 roleId 不在字典裡 → 貢獻零權限、不報錯。
        var permissions = Set(readModel.permissions ?? [])
        let roleGrants = try await roleDirectory.resolve(roleIds: readModel.roles)
        for grantedPermissions in roleGrants.values {
            permissions.formUnion(grantedPermissions)
        }
        return Array(permissions)
    }
}
