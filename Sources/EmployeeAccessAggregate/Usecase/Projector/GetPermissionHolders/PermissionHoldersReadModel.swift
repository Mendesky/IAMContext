import EventSourcing
import IAMContextShared

/// 反查讀模型：記錄目前「持有某 permission rawValue」的所有 userId。
/// id 對應 `IAM_PermissionHolders-<permission rawValue>` stream。
package class PermissionHoldersReadModel: ReadModel {
    package var id: String { permission }
    package var permission: String = ""
    /// 目前持有此 permission 的所有 userId（已 grant 且未被 revoke）。
    package var userIds: [String] = []

    package init(permission: String) {
        self.permission = permission
    }
}
