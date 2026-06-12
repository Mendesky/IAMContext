import DDDKit

package struct RevokePrivilegeService: RevokePrivilegeUsecase {
    package let repository: EmployeeAccessRepository

    package init(repository: EmployeeAccessRepository) {
        self.repository = repository
    }
}
