import DDDKit
import IAMContextShared

package protocol AssignRolesUsecase: Usecase where Input == AssignRolesInput, Output == AssignRolesOutput {
    var repository: EmployeeAccessRepository { get }
    /// 階段二（role-permission-composition §f）：roleId 存在性驗證的出埠。
    var roleDirectory: RoleDirectory { get }
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
