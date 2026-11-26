import Foundation
import KurrentDB
import IAMContextShared

package struct ChangeGrantScopeApplicationServiceInput {
    package let employeeAccessId: String
    package let userId: String
    package let permission: String
    package let grantScopes: [GrantScope]
    package let operatorId: String

    package init(employeeAccessId: String, userId: String, permission: String, grantScopes: [GrantScope], operatorId: String) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.permission = permission
        self.grantScopes = grantScopes
        self.operatorId = operatorId
    }
}

package struct ChangeGrantScopeApplicationServiceOutput {
    package let employeeAccessId: String
}

package struct ChangeGrantScopeApplicationService: ApplicationService {
    package typealias Input = ChangeGrantScopeApplicationServiceInput
    package typealias Output = ChangeGrantScopeApplicationServiceOutput

    private let repository: EmployeeAccessRepository
    private let grantScopePolicy: GrantScopePolicy
    private let effectivePermissionsReader: EffectivePermissionsReader

    package init(repository: EmployeeAccessRepository, kdbClient: KurrentDBClient, roleDirectory: RoleDirectory, grantScopePolicy: GrantScopePolicy) {
        self.repository = repository
        self.grantScopePolicy = grantScopePolicy
        self.effectivePermissionsReader = PermissionTimelineService(kdbClient: kdbClient, roleDirectory: roleDirectory)
    }

    package func execute(input: Input) async throws -> Output {
        let service = ChangeGrantScopeService(repository: repository, grantScopePolicy: grantScopePolicy, effectivePermissionsReader: effectivePermissionsReader)
        _ = try await service.execute(input: .init(
            employeeAccessId: input.employeeAccessId,
            userId: input.userId,
            permission: input.permission,
            grantScopes: input.grantScopes,
            operatorId: input.operatorId
        ))
        return .init(employeeAccessId: input.employeeAccessId)
    }
}
