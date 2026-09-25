import DDDKit
import Foundation
import IAMContextShared

package struct GetRolePermissionsApplicationServiceInput {
    package let roleId: String

    package init(roleId: String) {
        self.roleId = roleId
    }
}

package struct GetRolePermissionsApplicationService: ApplicationService {
    package typealias Input = GetRolePermissionsApplicationServiceInput
    package typealias Output = [String]

    private let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }

    package func execute(input: Input) async throws -> Output {
        guard let role = try await repository.find(byId: input.roleId) else {
            throw DDDError.aggregateNotFound(
                usecase: String(describing: GetRolePermissionsApplicationService.self),
                aggregateRootType: Role.self,
                aggregateRootId: input.roleId
            )
        }
        return Array(role.permissions ?? [])
    }
}
