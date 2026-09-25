import DDDKit

package struct AddPermissionsService: AddPermissionsUsecase {
    package let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }
}
