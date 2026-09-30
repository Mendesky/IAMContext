import EventSourcing
import IAMContextShared

/// 全角色清單讀模型：固定由 `IAM_GetRoles-all` stream 重建。
package class RolesReadModel: ReadModel {
    package var id: String { "all" }
    package var roles: [RoleSummary] = []

    package init() {}
}

package struct RoleSummary: Codable {
    package var roleId: String
    package var name: String
    package var description: String?
    package var permissions: [String]

    package init(roleId: String, name: String, description: String?, permissions: [String] = []) {
        self.roleId = roleId
        self.name = name
        self.description = description
        self.permissions = permissions
    }
}
