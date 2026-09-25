import DDDKit

package struct RemovePermissionsService: RemovePermissionsUsecase {
    package let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }
}
