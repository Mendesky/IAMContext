import DDDKit

package struct GrantPrivilegeService: GrantPrivilegeUsecase {
    package let repository: EmployeeAccessRepository
    package let effectivePermissionsReader: EffectivePermissionsReader
    package let grantScopePolicy: GrantScopePolicy

    package init(repository: EmployeeAccessRepository, effectivePermissionsReader: EffectivePermissionsReader, grantScopePolicy: GrantScopePolicy) {
        self.repository = repository
        self.effectivePermissionsReader = effectivePermissionsReader
        self.grantScopePolicy = grantScopePolicy
    }
}
