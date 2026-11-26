import DDDKit

package struct ChangeGrantScopeService: ChangeGrantScopeUsecase {
    package let repository: EmployeeAccessRepository
    package let grantScopePolicy: GrantScopePolicy
    package let effectivePermissionsReader: EffectivePermissionsReader

    package init(repository: EmployeeAccessRepository, grantScopePolicy: GrantScopePolicy, effectivePermissionsReader: EffectivePermissionsReader) {
        self.repository = repository
        self.grantScopePolicy = grantScopePolicy
        self.effectivePermissionsReader = effectivePermissionsReader
    }
}
