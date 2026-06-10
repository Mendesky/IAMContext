import DDDKit
import IAMContextShared

package protocol CreateUserAccessProfileUsecase: Usecase where Input == CreateUserAccessProfileInput, Output == CreateUserAccessProfileOutput {
    var repository: EmployeeAccessRepository { get }
}

extension CreateUserAccessProfileUsecase {
    package func execute(input: CreateUserAccessProfileInput) async throws -> CreateUserAccessProfileOutput {
        do {
            let employeeAccess = try EmployeeAccess(id: input.employeeAccessId, userId: input.userId, department: input.department, jobTitle: input.jobTitle)
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
