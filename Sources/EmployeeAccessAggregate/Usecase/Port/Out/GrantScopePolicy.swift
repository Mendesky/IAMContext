import Foundation
import IAMContextShared

/// 「哪些權限是範圍化的、允許哪些範圍種類」的出埠。
///
/// 資料來源是權限清單（`IAMPermissionCatalog` 的 `grantScopeKinds`），但 EmployeeAccessAggregate 刻意不依賴
/// 權限清單（見 `GetPermissionsApplicationService` 的說明），所以由 IAMContextServer 組裝時從權限清單建好注入；
/// 測試可以注入自己的對照表。RoleAggregate 也用同一個介面（角色不能放範圍化的權限）。
/// 設計：`docs/discussions/2026-11-25-scoped-permission-grant.md` D7、D10、D13。
package protocol GrantScopePolicy: Sendable {
    /// 範圍化的權限 → 允許的範圍種類。不是範圍化的權限不會出現在結果裡。
    func allowedKinds(for permissions: some Sequence<String>) -> [String: Set<GrantScopeKind>]
}

extension GrantScopePolicy {
    /// 這些權限裡有哪些是範圍化的。
    package func scopedPermissions(in permissions: some Sequence<String>) -> Set<String> {
        Set(allowedKinds(for: permissions).keys)
    }
}

/// 用固定對照表實作的 `GrantScopePolicy`。正式環境由權限清單建（`init(catalog:)`），測試直接給對照表。
package struct StaticGrantScopePolicy: GrantScopePolicy {
    package let kindsByPermission: [String: Set<GrantScopeKind>]

    package init(_ kindsByPermission: [String: Set<GrantScopeKind>]) {
        self.kindsByPermission = kindsByPermission
    }

    /// 從權限清單的 `grantScopeKinds`（權限 → 種類字串）建。不認得的種類字串略過；
    /// 權限清單裡寫的種類是否都認得，由測試守住（`GrantScopeCatalogTests`）。
    package init(catalog: [String: [String]]) {
        self.kindsByPermission = catalog.mapValues { Set($0.compactMap(GrantScopeKind.init(rawValue:))) }
    }

    /// 沒有任何範圍化權限（等同上線前的行為）。
    package static let none = StaticGrantScopePolicy([:])

    package func allowedKinds(for permissions: some Sequence<String>) -> [String: Set<GrantScopeKind>] {
        var result: [String: Set<GrantScopeKind>] = [:]
        for permission in permissions {
            if let kinds = kindsByPermission[permission] { result[permission] = kinds }
        }
        return result
    }
}
