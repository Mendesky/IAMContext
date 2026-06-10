import DDDKit
import IAMContextShared

package protocol GrantPrivilegeUsecase: Usecase where Input == GrantPrivilegeInput, Output == GrantPrivilegeOutput {
    var repository: EmployeeAccessRepository { get }
}

extension GrantPrivilegeUsecase {
    package func execute(input: GrantPrivilegeInput) async throws -> GrantPrivilegeOutput {
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            try employeeAccess.grantPrivilege(employeeAccessId: input.employeeAccessId, userId: input.userId, permissions: input.permissions)
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
