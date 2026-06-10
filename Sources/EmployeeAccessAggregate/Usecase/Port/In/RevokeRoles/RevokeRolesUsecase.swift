import DDDKit
import IAMContextShared

package protocol RevokeRolesUsecase: Usecase where Input == RevokeRolesInput, Output == RevokeRolesOutput {
    var repository: EmployeeAccessRepository { get }
}

extension RevokeRolesUsecase {
    package func execute(input: RevokeRolesInput) async throws -> RevokeRolesOutput {
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            try employeeAccess.revokeRoles(employeeAccessId: input.employeeAccessId, userId: input.userId, roles: input.roles)
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
