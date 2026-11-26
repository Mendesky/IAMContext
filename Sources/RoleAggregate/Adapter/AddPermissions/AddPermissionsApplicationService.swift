import IAMContextShared
import EmployeeAccessAggregate

package typealias AddPermissionsApplicationServiceInput = AddPermissionsInput
package typealias AddPermissionsApplicationServiceOutput = AddPermissionsOutput

package struct AddPermissionsApplicationService: ApplicationService {
    package typealias Input = AddPermissionsApplicationServiceInput
    package typealias Output = AddPermissionsApplicationServiceOutput

    private let repository: RoleRepository
    private let grantScopePolicy: GrantScopePolicy

    package init(repository: RoleRepository, grantScopePolicy: GrantScopePolicy) {
        self.repository = repository
        self.grantScopePolicy = grantScopePolicy
    }

    package func execute(input: Input) async throws -> Output {
        try await AddPermissionsService(repository: repository, grantScopePolicy: grantScopePolicy).execute(input: input)
    }
}
