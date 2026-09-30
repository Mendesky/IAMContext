import DDDKit

package struct CreateRoleService: CreateRoleUsecase {
    package let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }
}
