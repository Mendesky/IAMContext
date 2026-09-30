import EventSourcing
import IAMContextShared

/// 反查讀模型：記錄目前「持有某 roleId」的所有 userId。
/// id 對應 `IAM_GetRoleHolders-<roleId>` stream。
package class RoleHoldersReadModel: ReadModel {
    package var id: String { role }
    package var role: String = ""
    /// 目前持有此 role 的所有 userId（已 assign 且未 revoke）。
    package var userIds: [String] = []

    package init(role: String) {
        self.role = role
    }
}
