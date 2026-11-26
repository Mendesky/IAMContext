import DDDKit

package struct AssignRolesService: AssignRolesUsecase {
    package let repository: EmployeeAccessRepository
    package let roleDirectory: RoleDirectory
    package let grantScopePolicy: GrantScopePolicy

    package init(repository: EmployeeAccessRepository, roleDirectory: RoleDirectory, grantScopePolicy: GrantScopePolicy) {
        self.repository = repository
        self.roleDirectory = roleDirectory
        self.grantScopePolicy = grantScopePolicy
    }
}
