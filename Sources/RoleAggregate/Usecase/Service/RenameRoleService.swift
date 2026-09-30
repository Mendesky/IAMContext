import DDDKit

package struct RenameRoleService: RenameRoleUsecase {
    package let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }
}
