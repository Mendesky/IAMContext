import DDDKit

package struct RevokePrivilegeService: RevokePrivilegeUsecase {
    package let repository: EmployeeAccessRepository
    package let effectivePermissionsReader: EffectivePermissionsReader

    package init(repository: EmployeeAccessRepository, effectivePermissionsReader: EffectivePermissionsReader) {
        self.repository = repository
        self.effectivePermissionsReader = effectivePermissionsReader
    }
}
