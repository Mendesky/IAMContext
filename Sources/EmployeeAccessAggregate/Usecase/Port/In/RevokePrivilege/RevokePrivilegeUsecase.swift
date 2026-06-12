import DDDKit
import IAMContextShared

package protocol RevokePrivilegeUsecase: Usecase where Input == RevokePrivilegeInput, Output == RevokePrivilegeOutput {
    var repository: EmployeeAccessRepository { get }
}

extension RevokePrivilegeUsecase {
    package func execute(input: RevokePrivilegeInput) async throws -> RevokePrivilegeOutput {
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            try employeeAccess.revokePrivilege(employeeAccessId: input.employeeAccessId, userId: input.userId, permissions: input.permissions)
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
