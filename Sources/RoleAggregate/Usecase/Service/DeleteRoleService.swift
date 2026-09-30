import DDDKit

package struct DeleteRoleService: DeleteRoleUsecase {
    package let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }
}
