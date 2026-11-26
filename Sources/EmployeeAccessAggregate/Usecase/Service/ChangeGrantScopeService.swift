import DDDKit

package struct ChangeGrantScopeService: ChangeGrantScopeUsecase {
    package let repository: EmployeeAccessRepository
    package let grantScopePolicy: GrantScopePolicy

    package init(repository: EmployeeAccessRepository, grantScopePolicy: GrantScopePolicy) {
        self.repository = repository
        self.grantScopePolicy = grantScopePolicy
    }
}
