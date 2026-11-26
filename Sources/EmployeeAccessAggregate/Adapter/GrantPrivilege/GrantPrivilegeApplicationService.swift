import Foundation
import KurrentDB
import IAMContextShared

package struct GrantPrivilegeApplicationServiceInput {
    package let employeeAccessId: String
    package let userId: String
    package let permissions: [String]
    package let grantScopes: [String: [GrantScope]]
    package let operatorId: String

    package init(
        employeeAccessId: String,
        userId: String,
        permissions: [String],
        grantScopes: [String: [GrantScope]] = [:],
        operatorId: String
    ) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.permissions = permissions
        self.grantScopes = grantScopes
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
    private let grantScopePolicy: GrantScopePolicy

    package init(repository: EmployeeAccessRepository, kdbClient: KurrentDBClient, roleDirectory: RoleDirectory, grantScopePolicy: GrantScopePolicy) {
        self.repository = repository
        self.effectivePermissionsReader = PermissionTimelineService(kdbClient: kdbClient, roleDirectory: roleDirectory)
        self.grantScopePolicy = grantScopePolicy
    }

    package func execute(input: Input) async throws -> Output {
        let service = GrantPrivilegeService(repository: repository, effectivePermissionsReader: effectivePermissionsReader, grantScopePolicy: grantScopePolicy)
        _ = try await service.execute(input: .init(
            employeeAccessId: input.employeeAccessId,
            userId: input.userId,
            permissions: input.permissions,
            grantScopes: input.grantScopes,
            operatorId: input.operatorId
        ))
        return .init(employeeAccessId: input.employeeAccessId)
    }
}
