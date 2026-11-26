import Foundation
import Testing
import IAMPermissionCatalog

/// OIDCContext 權限快照（`Sources/IAMPermissionCatalog/OIDCContext.permissions.yaml`）經 PermissionCatalogPlugin 產生後的
/// 內容。不需要 KurrentDB。
///
/// 下面十一個值是 OIDCContext admin API 的權限（OIDCContext #14，規則在 OIDC 的
/// `Sources/OIDCAuthorization/OIDCContext.rules.yaml`）：OIDC admin listener 的 PermissionMiddleware 用它們守
/// `/admin/clients`（登入型 client）和 `/admin/applications`（系統憑證，資料在 IdentityContext）。console 的「應用程式授權」
/// 畫面在跑 gen:iam 之後引用。
/// 快照同步時改名或漏掉其中一個，這裡會失敗，角色就再也加不進這條權限（AddPermissions 會驗 catalog），
/// 使用者打對應的 admin 路由一律 403（application token、代理 token 和沒登入本來就是 401）。
/// OIDC 之後新增權限時，凍結值的檢查不會因為多出權限而失敗；格式和說明的檢查則套用到每一條權限（包括新增的）。
///
/// 快照和上游 SSOT 是否逐字相同，這裡不檢查（看不到上游 repo），要手動跑
/// `bash scripts/diff-permission-snapshots.sh OIDCContext`。
@Suite struct OIDCContextPermissionSnapshotTests {
    static let frozen: Set<String> = [
        "OIDCContext.Client.ViewClients",
        "OIDCContext.Client.CreateClient",
        "OIDCContext.Client.UpdateClient",
        "OIDCContext.Client.RotateClientSecret",
        "OIDCContext.Client.DeleteClient",
        "OIDCContext.ApplicationCredential.ViewApplicationCredentials",
        "OIDCContext.ApplicationCredential.CreateApplicationCredential",
        "OIDCContext.ApplicationCredential.RegenerateApplicationCredentialSecret",
        "OIDCContext.ApplicationCredential.DisableApplicationCredential",
        "OIDCContext.ApplicationCredential.EnableApplicationCredential",
        "OIDCContext.ApplicationCredential.ChangeApplicationCredentialNetworkAccess",
    ]

    @Test func catalogContainsTheFrozenOIDCContextPermissions() {
        #expect(Self.frozen.count == 11)
        #expect(PermissionCatalog.contexts.contains("OIDCContext"))
        // permissions(inContext:) 和 AddPermissionsUsecase 用的 allRawValues 都來自同一份 PermissionCatalog.all。
        let rawValues = Set(PermissionCatalog.permissions(inContext: "OIDCContext").map(\.rawValue))
        #expect(Self.frozen.subtracting(rawValues).sorted() == [])
        #expect(Self.frozen.subtracting(PermissionCatalog.allRawValues).sorted() == [])
    }

    @Test func everyOIDCContextPermissionHasADescriptionAndTheContextSlotOperationFormat() {
        let format = #/^OIDCContext\.[A-Z][A-Za-z0-9]*\.[A-Z][A-Za-z0-9]*$/#
        let infos = PermissionCatalog.permissions(inContext: "OIDCContext")
        #expect(!infos.isEmpty)
        for info in infos {
            #expect(info.rawValue.wholeMatch(of: format) != nil, "\(info.rawValue)")
            // console 的授權畫面顯示這段說明，管理員靠它判斷要不要授權。
            let description = info.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            #expect(!description.isEmpty, "\(info.rawValue)")
        }
    }
}
