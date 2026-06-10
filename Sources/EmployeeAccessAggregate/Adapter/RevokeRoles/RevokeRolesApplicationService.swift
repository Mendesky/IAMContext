import Foundation
import IAMContextShared

package struct RevokeRolesApplicationServiceInput {
    package let employeeAccessId: String
    package let userId: String
    package let roles: [String]
    package let operatorId: String

    package init(
        employeeAccessId: String,
        userId: String,
        roles: [String],
        operatorId: String
    ) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.roles = roles
        self.operatorId = operatorId
    }
}

package struct RevokeRolesApplicationServiceOutput {
    package let employeeAccessId: String
}

package struct RevokeRolesApplicationService: ApplicationService {
    package typealias Input = RevokeRolesApplicationServiceInput
    package typealias Output = RevokeRolesApplicationServiceOutput

    private let repository: EmployeeAccessRepository

    package init(repository: EmployeeAccessRepository) {
        self.repository = repository
    }

    package func execute(input: Input) async throws -> Output {
        let service = RevokeRolesService(repository: repository)
        _ = try await service.execute(input: .init(
            employeeAccessId: input.employeeAccessId,
            userId: input.userId,
            roles: input.roles,
            operatorId: input.operatorId
        ))
        return .init(employeeAccessId: input.employeeAccessId)
    }
}
