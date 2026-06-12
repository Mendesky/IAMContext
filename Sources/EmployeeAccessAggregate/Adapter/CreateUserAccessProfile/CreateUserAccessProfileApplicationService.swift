import Foundation
import IAMContextShared

package struct CreateUserAccessProfileApplicationServiceInput {
    package let employeeAccessId: String
    package let userId: String
    package let department: String
    package let jobTitle: String
    package let operatorId: String

    package init(
        employeeAccessId: String,
        userId: String,
        department: String,
        jobTitle: String,
        operatorId: String
    ) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.department = department
        self.jobTitle = jobTitle
        self.operatorId = operatorId
    }
}

package struct CreateUserAccessProfileApplicationServiceOutput {
    package let employeeAccessId: String
}

package struct CreateUserAccessProfileApplicationService: ApplicationService {
    package typealias Input = CreateUserAccessProfileApplicationServiceInput
    package typealias Output = CreateUserAccessProfileApplicationServiceOutput

    private let repository: EmployeeAccessRepository

    package init(repository: EmployeeAccessRepository) {
        self.repository = repository
    }

    package func execute(input: Input) async throws -> Output {
        let service = CreateUserAccessProfileService(repository: repository)
        _ = try await service.execute(input: .init(
            employeeAccessId: input.employeeAccessId,
            userId: input.userId,
            department: input.department,
            jobTitle: input.jobTitle,
            operatorId: input.operatorId
        ))
        return .init(employeeAccessId: input.employeeAccessId)
    }
}
