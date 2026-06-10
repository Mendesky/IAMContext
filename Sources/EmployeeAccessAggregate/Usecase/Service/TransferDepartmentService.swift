import DDDKit

package struct TransferDepartmentService: TransferDepartmentUsecase {
    package let repository: EmployeeAccessRepository

    package init(repository: EmployeeAccessRepository) {
        self.repository = repository
    }
}
