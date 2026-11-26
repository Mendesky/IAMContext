import DDDKit
import IAMContextShared
import IAMPermissionCatalog
import EmployeeAccessAggregate

package protocol AddPermissionsUsecase: Usecase where Input == AddPermissionsInput, Output == AddPermissionsOutput {
    var repository: RoleRepository { get }
    /// 角色不能帶範圍（2026-11-25 設計文件 D13）：範圍化的權限不能放進角色。
    var grantScopePolicy: GrantScopePolicy { get }
}

extension AddPermissionsUsecase {
    package func execute(input: AddPermissionsInput) async throws -> AddPermissionsOutput {
        do {
            guard input.permissions.allSatisfy({ PermissionCatalog.allRawValues.contains($0) }) else {
                throw ContextError<RoleError>.invalidPermission(function: #function, message: "permissions must all exist in PermissionCatalog")
            }
            let scoped = grantScopePolicy.scopedPermissions(in: input.permissions)
            guard scoped.isEmpty else {
                throw ContextError<RoleError>.scopedPermissionNotAllowed(function: #function, message: "scoped permissions cannot be added to a role: \(scoped.sorted())")
            }
            guard let role = try await repository.find(byId: input.roleId) else {
                throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: Role.self, aggregateRootId: input.roleId)
            }
            try role.addPermissions(roleId: input.roleId, permissions: Set(input.permissions))
            try await repository.save(aggregateRoot: role, userId: input.operatorId)
            return .init(roleId: role.id, message: nil)
        } catch let error as ContextError<RoleError> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
    }
}
