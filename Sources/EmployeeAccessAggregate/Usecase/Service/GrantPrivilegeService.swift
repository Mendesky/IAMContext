import DDDKit

package struct GrantPrivilegeService: GrantPrivilegeUsecase {
    package let repository: EmployeeAccessRepository
    package let effectivePermissionsReader: EffectivePermissionsReader

    package init(repository: EmployeeAccessRepository, effectivePermissionsReader: EffectivePermissionsReader) {
        self.repository = repository
        self.effectivePermissionsReader = effectivePermissionsReader
    }
}
