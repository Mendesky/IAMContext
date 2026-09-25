import EventSourcing
import IAMContextShared

package class PermissionsReadModel: ReadModel {
    package var id: String { employeeAccessId }
    // NOTE: bundle storedFields declared employeeAccessId defaultValue "" but scaffold omitted it →
    // init(userId:) left it uninitialized. Restored default to match bundle (read-side scaffold fix, out of /domain-fill scope).
    package var employeeAccessId: String = ""
    package var userId: String?
    package var permissions: Array<String>?
    /// 員工目前持有的 roleId 集合（RolesAssigned 聯集、RolesRevoked 差集）。
    /// 階段二（role-permission-composition）新增：getPermissions 以此向 RoleDirectory 解析角色展開的權限。
    package var roles: Set<String> = []
    /// 員工目前所在部門（由 UserAccessProfileCreated 設定，DepartmentTransferred 更新）。
    package var department: String?
    /// 員工目前所別（由 UserAccessProfileCreated 設定，DepartmentTransferred 帶 newFirm 時更新）。
    package var firm: String?

    package init(userId: String) {
        self.userId = userId
    }
}
