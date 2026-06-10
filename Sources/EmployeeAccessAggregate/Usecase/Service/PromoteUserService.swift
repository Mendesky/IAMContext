import DDDKit

package struct PromoteUserService: PromoteUserUsecase {
    package let repository: EmployeeAccessRepository

    package init(repository: EmployeeAccessRepository) {
        self.repository = repository
    }
}
