import DDDKit
import IAMContextShared

package protocol PromoteUserUsecase: Usecase where Input == PromoteUserInput, Output == PromoteUserOutput {
    var repository: EmployeeAccessRepository { get }
}

extension PromoteUserUsecase {
    package func execute(input: PromoteUserInput) async throws -> PromoteUserOutput {
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            try employeeAccess.promoteUser(employeeAccessId: input.employeeAccessId, userId: input.userId, newJobTitle: input.newJobTitle, oldJobTitle: input.oldJobTitle)
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
