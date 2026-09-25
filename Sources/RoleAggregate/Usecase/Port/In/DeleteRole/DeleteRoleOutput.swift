import DDDKit

package struct DeleteRoleOutput: UseCaseOutput {
    package let roleId: String
    package var id: String? { roleId }
    package let message: String?

    package init(roleId: String, message: String? = nil) {
        self.roleId = roleId
        self.message = message
    }
}
