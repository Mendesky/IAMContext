import DDDKit

package struct RevokeRolesService: RevokeRolesUsecase {
    package let repository: EmployeeAccessRepository

    package init(repository: EmployeeAccessRepository) {
        self.repository = repository
    }
}
