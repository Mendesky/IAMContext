import DDDKit

package struct AssignRolesService: AssignRolesUsecase {
    package let repository: EmployeeAccessRepository
    package let roleDirectory: RoleDirectory

    package init(repository: EmployeeAccessRepository, roleDirectory: RoleDirectory) {
        self.repository = repository
        self.roleDirectory = roleDirectory
    }
}
