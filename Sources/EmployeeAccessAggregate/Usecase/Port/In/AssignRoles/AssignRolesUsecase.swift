import DDDKit
import IAMContextShared

package protocol AssignRolesUsecase: Usecase where Input == AssignRolesInput, Output == AssignRolesOutput {
    var repository: EmployeeAccessRepository { get }
}

extension AssignRolesUsecase {
    package func execute(input: AssignRolesInput) async throws -> AssignRolesOutput {
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
