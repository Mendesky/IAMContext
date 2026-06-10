import DDDKit

package struct GrantPrivilegeService: GrantPrivilegeUsecase {
    package let repository: EmployeeAccessRepository

    package init(repository: EmployeeAccessRepository) {
        self.repository = repository
    }
}
