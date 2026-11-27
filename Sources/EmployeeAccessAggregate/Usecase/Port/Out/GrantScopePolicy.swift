import Foundation
import IAMContextShared

/// 「哪些權限是範圍化的、用哪個範圍類型、允許哪些種類」的出埠。
///
/// 資料來源是權限清單（`IAMPermissionCatalog` 的 `grant-scope-types.yaml` 與各權限的 `grantScope`），但 EmployeeAccessAggregate
/// 刻意不依賴權限清單（見 `GetPermissionsApplicationService` 的說明），所以由 IAMContextServer 組裝時從權限清單建好注入；
/// 測試可以注入自己的對照表。RoleAggregate 也用同一個介面（角色不能放範圍化的權限）。
/// 設計：`docs/discussions/2026-11-25-scoped-permission-grant.md` D7、D10、D13、D22。
package protocol GrantScopePolicy: Sendable {
    /// 範圍化的權限 → 範圍規則。不是範圍化的權限不會出現在結果裡。
    func rules(for permissions: some Sequence<String>) -> [String: GrantScopeRule]
}

extension GrantScopePolicy {
    /// 這些權限裡有哪些是範圍化的。
    package func scopedPermissions(in permissions: some Sequence<String>) -> Set<String> {
        Set(rules(for: permissions).keys)
    }
}

/// 用固定對照表實作的 `GrantScopePolicy`。正式環境由權限清單建（`init(types:permissions:)`），測試直接給對照表。
package struct StaticGrantScopePolicy: GrantScopePolicy {
    package let rulesByPermission: [String: GrantScopeRule]

    package init(_ rulesByPermission: [String: GrantScopeRule]) {
        self.rulesByPermission = rulesByPermission
    }

    /// 從權限清單建：`types` 是範圍類型定義，`permissions` 是範圍化的權限 → (類型, 允許的種類)。
    /// 權限寫了不存在的類型就略過那個權限，類型底下沒有的種類也略過；權限清單寫的是否都存在，
    /// 由 permission-catalog-gen 在 build 時檢查（寫錯 build 不過）。
    package init(types: [GrantScopeTypeDefinition], permissions: [String: (type: String, kinds: [String])]) {
        let typesByName = Dictionary(types.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first })
        var rules: [String: GrantScopeRule] = [:]
        for (permission, spec) in permissions {
            guard let type = typesByName[spec.type] else { continue }
            rules[permission] = GrantScopeRule(type: type, allowedKinds: Set(spec.kinds.filter { type.kinds[$0] != nil }))
        }
        self.rulesByPermission = rules
    }

    /// 沒有任何範圍化權限（等同上線前的行為）。
    package static let none = StaticGrantScopePolicy([:])

    package func rules(for permissions: some Sequence<String>) -> [String: GrantScopeRule] {
        var result: [String: GrantScopeRule] = [:]
        for permission in permissions {
            if let rule = rulesByPermission[permission] { result[permission] = rule }
        }
        return result
    }
}
