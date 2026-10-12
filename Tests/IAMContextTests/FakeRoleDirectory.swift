import EmployeeAccessAggregate

/// 測試用假 RoleDirectory（docs/tasks/role-permission-composition.md「測試基礎設施」）。
/// - `resolved == nil`（預設，permissive 模式）：任何 roleId 都視為存在，回傳一個以自己命名的哨兵權限
///   （`"__fake_permission_from_<roleId>__"`）——只保證 assignRoles 的存在性驗證通過；既有測試不斷言角色展開的具體權限。
/// - `resolved` 給定字典：顯式模式，只有字典裡的 key 視為存在（傳空字典可模擬「角色不存在」）。
/// - `everContaining`：`rolesEverContaining(permission:)` 的查詢表，預設空（等同「沒有任何角色曾含此權限」）。
struct FakeRoleDirectory: RoleDirectory {
    private let resolved: [String: Set<String>]?
    private let everContaining: [String: Set<String>]
    private let histories: [String: [TimelineEntry]]

    init(resolved: [String: Set<String>]? = nil,
         everContaining: [String: Set<String>] = [:],
         histories: [String: [TimelineEntry]] = [:]) {
        self.resolved = resolved
        self.everContaining = everContaining
        self.histories = histories
    }

    func resolve(roleIds: Set<String>) async throws -> [String: Set<String>] {
        if let resolved {
            return resolved.filter { roleIds.contains($0.key) }
        }
        return Dictionary(uniqueKeysWithValues: roleIds.map { ($0, Set(["__fake_permission_from_\($0)__"])) })
    }

    func history(ofRoles roleIds: Set<String>) async throws -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        for roleId in roleIds.sorted() {
            if let explicit = histories[roleId] {
                entries += explicit
                continue
            }
            let permissions: Set<String>
            if let resolved {
                guard let known = resolved[roleId] else { continue }
                permissions = known
            } else {
                permissions = ["__fake_permission_from_\(roleId)__"]
            }
            let origin = LogPosition(commit: 0, prepare: 0)
            entries.append(.init(position: origin, event: .roleCreated(roleId: roleId)))
            if !permissions.isEmpty {
                entries.append(.init(position: origin, event: .rolePermissionsAdded(roleId: roleId, permissions: permissions)))
            }
        }
        return entries
    }

    func rolesEverContaining(permission: String) async throws -> Set<String> {
        everContaining[permission] ?? []
    }

}
