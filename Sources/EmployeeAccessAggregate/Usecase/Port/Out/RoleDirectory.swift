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

    /// 回傳目前仍存在（未刪除）且權限集合包含 `permission` 的所有 roleId。
    ///
    /// 走 GetRoles 目錄（projection，最終一致）；projection 未部署／尚無角色時回空集合，不報錯。
    func rolesContaining(permission: String) async throws -> Set<String>
}
