import DDDKit
import EmployeeAccessAggregate

package struct AddPermissionsService: AddPermissionsUsecase {
    package let repository: RoleRepository
    package let grantScopePolicy: GrantScopePolicy

    package init(repository: RoleRepository, grantScopePolicy: GrantScopePolicy) {
        self.repository = repository
        self.grantScopePolicy = grantScopePolicy
    }
}
