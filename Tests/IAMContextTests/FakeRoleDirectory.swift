import EmployeeAccessAggregate

/// 測試用假 RoleDirectory（docs/tasks/role-permission-composition.md「測試基礎設施」）。
/// - `resolved == nil`（預設，permissive 模式）：任何 roleId 都視為存在，回傳一個以自己命名的哨兵權限
///   （`"__fake_permission_from_<roleId>__"`）——只保證 assignRoles 的存在性驗證通過；既有測試不斷言角色展開的具體權限。
/// - `resolved` 給定字典：顯式模式，只有字典裡的 key 視為存在（傳空字典可模擬「角色不存在」）。
/// - `containing`：`rolesContaining(permission:)` 的查詢表，預設空（等同「沒有任何角色含此權限」）。
struct FakeRoleDirectory: RoleDirectory {
    private let resolved: [String: Set<String>]?
    private let containing: [String: Set<String>]

    init(resolved: [String: Set<String>]? = nil, containing: [String: Set<String>] = [:]) {
        self.resolved = resolved
        self.containing = containing
    }

    func resolve(roleIds: Set<String>) async throws -> [String: Set<String>] {
        if let resolved {
            return resolved.filter { roleIds.contains($0.key) }
        }
        return Dictionary(uniqueKeysWithValues: roleIds.map { ($0, Set(["__fake_permission_from_\($0)__"])) })
    }

    func rolesContaining(permission: String) async throws -> Set<String> {
        containing[permission] ?? []
    }
}
