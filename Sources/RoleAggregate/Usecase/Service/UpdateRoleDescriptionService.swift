import DDDKit

package struct UpdateRoleDescriptionService: UpdateRoleDescriptionUsecase {
    package let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }
}
