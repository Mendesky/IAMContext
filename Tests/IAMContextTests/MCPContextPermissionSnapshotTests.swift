import Foundation
import Testing
import IAMPermissionCatalog

/// MCPContext 權限快照（`Sources/IAMPermissionCatalog/MCPContext.permissions.yaml`）經 PermissionCatalogPlugin
/// 產生後的內容。不需要 KurrentDB。
///
/// 下面三個值是 claude-connector 介面規格 I1 凍結的權限
/// （claude-connector/plans/2026-11-25-mcp-iam-interfaces.md）。預定由 MCP 的 tools/call 檢查（A4）、
/// IdentityContext client policy 的 `required_permission`（B1）、console 的授權畫面（A3 跑 gen:iam 之後）引用；
/// 本 PR 合併時都還沒上線。
/// 快照同步時改名或漏掉其中一個，這裡會失敗。MCPContext 之後新增工具時，凍結值的檢查不會因為多出權限而失敗；
/// 格式和說明的檢查則套用到 MCPContext 的每一條權限（包括新增的）。
///
/// 快照和上游 SSOT 是否逐字相同，這裡不檢查（看不到上游 repo），要手動跑
/// `bash scripts/diff-permission-snapshots.sh MCPContext`。
@Suite struct MCPContextPermissionSnapshotTests {
    static let frozen: Set<String> = [
        "MCPContext.Connector.UseConnector",
        "MCPContext.Tools.ListMyQuotes",
        "MCPContext.Tools.LookupBusinessRegistration",
    ]

    @Test func catalogContainsTheFrozenMCPContextPermissions() {
        #expect(PermissionCatalog.contexts.contains("MCPContext"))
        // permissions(inContext:) 和 AddPermissionsUsecase 用的 allRawValues 都來自同一份 PermissionCatalog.all。
        let rawValues = Set(PermissionCatalog.permissions(inContext: "MCPContext").map(\.rawValue))
        #expect(Self.frozen.subtracting(rawValues).sorted() == [])
    }

    @Test func everyMCPContextPermissionHasADescriptionAndTheFrozenFormat() {
        // 介面規格 I2：IdentityContext／OIDC 對 required_permission 的格式檢查。
        let format = #/^[A-Z][A-Za-z0-9]*\.[A-Z][A-Za-z0-9]*\.[A-Z][A-Za-z0-9]*$/#
        let infos = PermissionCatalog.permissions(inContext: "MCPContext")
        #expect(!infos.isEmpty)
        for info in infos {
            #expect(info.rawValue.wholeMatch(of: format) != nil, "\(info.rawValue)")
            // console 的授權畫面顯示這段說明，管理員靠它判斷要不要授權。
            let description = info.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            #expect(!description.isEmpty, "\(info.rawValue)")
        }
    }
}
