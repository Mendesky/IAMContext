import Foundation
import IAMContextShared

package struct AssignRolesApplicationServiceInput {
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

package struct AssignRolesApplicationServiceOutput {
    package let employeeAccessId: String
}

package struct AssignRolesApplicationService: ApplicationService {
    package typealias Input = AssignRolesApplicationServiceInput
    package typealias Output = AssignRolesApplicationServiceOutput

    private let repository: EmployeeAccessRepository
    private let roleDirectory: RoleDirectory

    package init(repository: EmployeeAccessRepository, roleDirectory: RoleDirectory) {
        self.repository = repository
        self.roleDirectory = roleDirectory
    }

    package func execute(input: Input) async throws -> Output {
        let service = AssignRolesService(repository: repository, roleDirectory: roleDirectory)
        _ = try await service.execute(input: .init(
            employeeAccessId: input.employeeAccessId,
            userId: input.userId,
            roles: input.roles,
            operatorId: input.operatorId
        ))
        return .init(employeeAccessId: input.employeeAccessId)
    }
}
