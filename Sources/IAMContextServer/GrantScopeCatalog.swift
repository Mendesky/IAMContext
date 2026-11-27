import EmployeeAccessAggregate
import IAMContextShared
import IAMPermissionCatalog

/// 權限清單 → 授權範圍規則。授權、改範圍、指派角色、角色加權限、除錯模式的範圍查詢都用這一份；HTTP 與 gRPC 共用。
/// 類型定義來自 `grant-scope-types.yaml`，各權限的類型與種類來自權限清單的 `grantScope`
/// （設計：docs/discussions/2026-11-25-scoped-permission-grant.md D22）。
enum GrantScopeCatalog {
    static let policy = StaticGrantScopePolicy(
        types: PermissionCatalog.grantScopeTypes.map(definition(of:)),
        permissions: PermissionCatalog.grantScopes.mapValues { (type: $0.type, kinds: $0.kinds) }
    )

    /// IAM_DEBUG_FULL_PERMISSIONS 開啟時的範圍查詢結果：每個範圍化的權限都回它類型的不限範圍種類。
    static var debugOverride: [PermissionGrantScopes] {
        GetPermissionGrantScopesApplicationService.debugOverride(rules: policy.rulesByPermission)
    }

    static func definition(of info: CatalogGrantScopeType) -> GrantScopeTypeDefinition {
        GrantScopeTypeDefinition(
            type: info.type,
            unrestrictedKind: info.unrestrictedKind,
            kinds: info.kinds.map { GrantScopeKindDefinition(kind: $0.kind, takesValues: $0.takesValues, valuePattern: $0.valuePattern) }
        )
    }
}
