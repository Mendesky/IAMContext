import IAMContextShared
import IAMPermissionCatalog
@testable import IAMContextServer

// 測試用的組織範圍（type = organization）。正式程式不認得任何具體類型（類型定義在權限清單的 grant-scope-types.yaml），
// 所以這些捷徑只放在測試裡。類型定義直接取權限清單產出的那一份，測的就是正式用的格式規則。

extension GrantScope {
    static let company = GrantScope(type: "organization", kind: "company")
    static let ownFirm = GrantScope(type: "organization", kind: "ownFirm")
    static let ownDepartment = GrantScope(type: "organization", kind: "ownDepartment")
    static func firms(_ firms: [String]) -> GrantScope {
        GrantScope(type: "organization", kind: "firms", values: firms)
    }
    /// 指定組：每個值是「所統編/組名」。
    static func departments(_ departments: [String]) -> GrantScope {
        GrantScope(type: "organization", kind: "departments", values: departments)
    }
}

enum OrganizationScope {
    /// 權限清單裡的組織類型定義。
    static let type: GrantScopeTypeDefinition = {
        guard let info = PermissionCatalog.grantScopeTypes.first(where: { $0.type == "organization" }) else {
            preconditionFailure("grant-scope-types.yaml 沒有 organization 類型")
        }
        return GrantScopeCatalog.definition(of: info)
    }()

    static let allKinds: Set<String> = Set(type.kinds.keys)

    /// 用組織類型、允許 `kinds` 的範圍規則（預設五種都允許）。
    static func rule(_ kinds: Set<String> = allKinds) -> GrantScopeRule {
        GrantScopeRule(type: type, allowedKinds: kinds)
    }
}
