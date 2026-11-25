import Testing
import IAMPermissionCatalog

/// MCPContext 權限快照（`Sources/IAMPermissionCatalog/MCPContext.permissions.yaml`）經 PermissionCatalogPlugin
/// 產生後的內容。不需要 KurrentDB。
///
/// 下面三個值是 claude-connector 介面規格 I1 凍結的權限：IdentityContext 的 client policy
/// （`required_permission`）、MCP 的 tools/call 檢查、console 的授權畫面都直接引用這幾個字串。
/// 快照同步時改名或漏掉其中一個，授權畫面就挑不到、或授了也對不上，這裡會失敗。
/// MCPContext 之後新增工具時，快照多出權限不會讓這裡失敗。
///
/// 快照和上游 SSOT 是否逐字相同，用 `scripts/diff-permission-snapshots.sh MCPContext` 比對（本測試看不到上游 repo）。
@Suite struct MCPContextPermissionSnapshotTests {
    static let frozen: Set<String> = [
        "MCPContext.Connector.UseConnector",
        "MCPContext.Tools.ListMyQuotes",
        "MCPContext.Tools.LookupBusinessRegistration",
    ]

    @Test func catalogContainsTheFrozenMCPContextPermissions() {
        #expect(PermissionCatalog.contexts.contains("MCPContext"))
        let rawValues = Set(PermissionCatalog.permissions(inContext: "MCPContext").map(\.rawValue))
        #expect(Self.frozen.subtracting(rawValues).sorted() == [])
        // 角色加權限時只接受 catalog 裡的值（AddPermissionsUsecase）。
        #expect(Self.frozen.subtracting(PermissionCatalog.allRawValues).sorted() == [])
    }

    @Test func everyMCPContextPermissionHasADescriptionAndTheFrozenFormat() {
        // 介面規格 I2：IdentityContext／OIDC 對 required_permission 的格式檢查。
        let format = #/^[A-Z][A-Za-z0-9]*\.[A-Z][A-Za-z0-9]*\.[A-Z][A-Za-z0-9]*$/#
        let infos = PermissionCatalog.permissions(inContext: "MCPContext")
        #expect(!infos.isEmpty)
        for info in infos {
            #expect(info.rawValue.wholeMatch(of: format) != nil, "\(info.rawValue)")
            // console 的授權畫面顯示這段說明，管理員靠它判斷要不要授權。
            #expect(info.description.map { !$0.isEmpty } == true, "\(info.rawValue)")
        }
    }
}
