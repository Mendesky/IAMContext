import Foundation
import IAMContextShared

package struct PromoteUserApplicationServiceInput {
    package let employeeAccessId: String
    package let userId: String
    package let newJobTitle: String
    package let oldJobTitle: String
    package let operatorId: String

    package init(
        employeeAccessId: String,
        userId: String,
        newJobTitle: String,
        oldJobTitle: String,
        operatorId: String
    ) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.newJobTitle = newJobTitle
        self.oldJobTitle = oldJobTitle
        self.operatorId = operatorId
    }
}

package struct PromoteUserApplicationServiceOutput {
    package let employeeAccessId: String
}

package struct PromoteUserApplicationService: ApplicationService {
    package typealias Input = PromoteUserApplicationServiceInput
    package typealias Output = PromoteUserApplicationServiceOutput

    private let repository: EmployeeAccessRepository

    package init(repository: EmployeeAccessRepository) {
        self.repository = repository
    }

    package func execute(input: Input) async throws -> Output {
        let service = PromoteUserService(repository: repository)
        _ = try await service.execute(input: .init(
            employeeAccessId: input.employeeAccessId,
            userId: input.userId,
            newJobTitle: input.newJobTitle,
            oldJobTitle: input.oldJobTitle,
            operatorId: input.operatorId
        ))
        return .init(employeeAccessId: input.employeeAccessId)
    }
}
