import DDDKit
import IAMContextShared

package protocol AssignRolesUsecase: Usecase where Input == AssignRolesInput, Output == AssignRolesOutput {
    var repository: EmployeeAccessRepository { get }
    /// 階段二（role-permission-composition §f）：roleId 存在性驗證的出埠。
    var roleDirectory: RoleDirectory { get }
    /// 角色不能帶範圍（2026-11-25 設計文件 D13）：角色裡有範圍化的權限就不能指派。
    var grantScopePolicy: GrantScopePolicy { get }
}

extension AssignRolesUsecase {
    package func execute(input: AssignRolesInput) async throws -> AssignRolesOutput {
        // 階段二：每個 roleId 必須指向存在且未刪除的 Role（驗證放 usecase 層、不放 aggregate，比照 D7）。
        // 放在 repository.find 之前——不存在的 roleId 不需要先讀 employeeAccess 就能拒絕。
        let requestedRoleIds = Set(input.roles)
        let resolved = try await roleDirectory.resolve(roleIds: requestedRoleIds)
        guard requestedRoleIds.isSubset(of: Set(resolved.keys)) else {
            let missing = requestedRoleIds.subtracting(resolved.keys).sorted()
            throw ContextError<EmployeeAccessError>.roleNotFound(function: #function, message: "roleId not found or already deleted: \(missing)")
        }
        // 角色不能帶範圍（D13）：角色裡已經有範圍化的權限（規則上線前建的角色、或之後才範圍化的權限），
        // 指派下去那個人會拿到沒有範圍的範圍化權限，所以整批拒絕。
        let scopedInRoles = requestedRoleIds.sorted().compactMap { roleId -> String? in
            let scoped = grantScopePolicy.scopedPermissions(in: resolved[roleId] ?? [])
            return scoped.isEmpty ? nil : "\(roleId): \(scoped.sorted())"
        }
        guard scopedInRoles.isEmpty else {
            throw ContextError<EmployeeAccessError>.roleContainsScopedPermission(function: #function, message: "roles contain scoped permissions: \(scopedInRoles)")
        }
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            try employeeAccess.assignRoles(employeeAccessId: input.employeeAccessId, userId: input.userId, roles: input.roles)
            try await repository.save(aggregateRoot: employeeAccess, userId: input.operatorId)
            return .init(id: employeeAccess.id, message: nil)
        } catch let error as ContextError<EmployeeAccessError> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
    }
}
