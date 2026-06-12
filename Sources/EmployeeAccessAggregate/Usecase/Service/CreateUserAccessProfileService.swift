import DDDKit

package struct CreateUserAccessProfileService: CreateUserAccessProfileUsecase {
    package let repository: EmployeeAccessRepository

    package init(repository: EmployeeAccessRepository) {
        self.repository = repository
    }
}
