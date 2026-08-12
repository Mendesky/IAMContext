import DDDKit
import IAMContextShared

package protocol TransferDepartmentUsecase: Usecase where Input == TransferDepartmentInput, Output == TransferDepartmentOutput {
    var repository: EmployeeAccessRepository { get }
}

extension TransferDepartmentUsecase {
    package func execute(input: TransferDepartmentInput) async throws -> TransferDepartmentOutput {
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            try employeeAccess.transferDepartment(employeeAccessId: input.employeeAccessId, userId: input.userId, newDepartment: input.newDepartment, newJobTitle: input.newJobTitle, newFirm: input.newFirm)
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
