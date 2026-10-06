import Foundation

/// EmployeeAccessAggregate 對「角色定義」的唯一出埠（outgoing port）。
///
/// EmployeeAccessAggregate target 不依賴 RoleAggregate target——生產實作由 RoleAggregate 端提供
/// （`RoleAggregateDirectory`），在 IAMContextServer 組裝時注入；整合測試可注入假的目錄。
/// 設計來源：docs/2026-09-21-role-mechanism-plan.html 第五節「落地位置」、docs/tasks/role-permission-composition.md §a。
package protocol RoleDirectory: Sendable {
    /// 解析一批 roleId 各自的權限集合。
    ///
    /// 查不到或已刪除的 roleId **不出現在結果字典的 key 中**（不是回空集合值）——
    /// 呼叫端用 `resolved.keys` 判斷「這個 roleId 有效」（assignRoles 的存在性驗證即依此）。
    func resolve(roleIds: Set<String>) async throws -> [String: Set<String>]

    /// 這些角色的權限相關歷史事件，每個角色從 `RoleCreated` 開始到目前為止（含已刪除角色的
    /// `RoleDeleted`；P-b：刪除是 append 事件，原始事件仍可讀）。
    /// - 只回 `roleCreated`／`rolePermissionsAdded`／`rolePermissionsRemoved`／`roleDeleted` 四種
    ///   role 事件（`RoleRenamed`／`RoleDescriptionUpdated` 不影響權限，**明確列名忽略**）。
    /// - `position` 是原始事件的全域位置。
    /// - 沒有對應 stream 的 roleId（歷史舊字串、從未建立）不產生任何 entry，也不報錯（貢獻零權限）。
    /// - fail-closed：事件無法解析、無法解碼、型別未登記或未處理時拋 `PermissionTimelineError`（或 mapper 的解碼錯誤），
    ///   不略過、不回部分歷史。
    /// - 回傳順序不保證；呼叫端併入時間軸後由 `PermissionTimeline.replay` 依位置排序。
    /// - 強一致：直接讀角色原始 stream，不經 projection。
    func history(ofRoles roleIds: Set<String>) async throws -> [TimelineEntry]

    /// 任何時候含過 `permission` 的角色 roleId，
    /// **包含目前已刪除的角色，也包含後來被移除該權限的角色**（D6 的候選人來源）。
    /// 走 `IAM_GetRoles-all` link stream 的 `RolePermissionsAdded` 事件（不折疊；最終一致）。
    /// projection 未部署或尚無角色時回空集合，不報錯；KurrentDB 不可用等其他錯誤向上拋。
    func rolesEverContaining(permission: String) async throws -> Set<String>

}
