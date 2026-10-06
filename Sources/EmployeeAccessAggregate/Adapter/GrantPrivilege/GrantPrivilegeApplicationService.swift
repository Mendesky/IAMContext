import Foundation
import KurrentDB
import IAMContextShared

package struct GrantPrivilegeApplicationServiceInput {
    package let employeeAccessId: String
    package let userId: String
    package let permissions: [String]
    package let operatorId: String

    package init(
        employeeAccessId: String,
        userId: String,
        permissions: [String],
        operatorId: String
    ) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.permissions = permissions
        self.operatorId = operatorId
    }
}

package struct GrantPrivilegeApplicationServiceOutput {
    package let employeeAccessId: String
}

package struct GrantPrivilegeApplicationService: ApplicationService {
    package typealias Input = GrantPrivilegeApplicationServiceInput
    package typealias Output = GrantPrivilegeApplicationServiceOutput

    private let repository: EmployeeAccessRepository
    private let effectivePermissionsReader: EffectivePermissionsReader

    package init(repository: EmployeeAccessRepository, kdbClient: KurrentDBClient, roleDirectory: RoleDirectory) {
        self.repository = repository
        self.effectivePermissionsReader = PermissionTimelineService(kdbClient: kdbClient, roleDirectory: roleDirectory)
    }

    package func execute(input: Input) async throws -> Output {
        let service = GrantPrivilegeService(repository: repository, effectivePermissionsReader: effectivePermissionsReader)
        _ = try await service.execute(input: .init(
            employeeAccessId: input.employeeAccessId,
            userId: input.userId,
            permissions: input.permissions,
            operatorId: input.operatorId
        ))
        return .init(employeeAccessId: input.employeeAccessId)
    }
}
