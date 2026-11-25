import Foundation
import Testing
import IAMPermissionCatalog

/// VersionManagementContext 權限快照（`Sources/IAMPermissionCatalog/VersionManagementContext.permissions.yaml`）
/// 經 PermissionCatalogPlugin 產生後的內容。不需要 KurrentDB。
///
/// 下面三個值是 VMC 憑證路由的權限（VersionManagementContext #18，規則在 VMC 的
/// `Sources/VMCAuthorization/VersionManagementContext.rules.yaml`）：VMC 的 PermissionMiddleware 用它們守
/// `GET /products/{productId}/application`、`POST …/credential`、`POST …/credential/secret`，
/// `POST /products/` 也用 CreateProductCredential 決定要不要一併發憑證。console 的授權畫面在跑 gen:iam 之後引用。
/// 快照同步時改名或漏掉其中一個，這裡會失敗，角色就再也加不進這條權限（AddPermissions 會驗 catalog），
/// VMC 開了權限檢查之後，使用者打憑證路由一律 403（application token 和沒登入本來就是 401）。
/// VMC 之後新增權限時，凍結值的檢查不會因為多出權限而失敗；格式和說明的檢查則套用到每一條權限（包括新增的）。
///
/// 快照和上游 SSOT 是否逐字相同，這裡不檢查（看不到上游 repo）。
@Suite struct VersionManagementContextPermissionSnapshotTests {
    static let frozen: Set<String> = [
        "VersionManagementContext.Product.GetProductApplication",
        "VersionManagementContext.Product.CreateProductCredential",
        "VersionManagementContext.Product.RegenerateProductCredentialSecret",
    ]

    @Test func catalogContainsTheFrozenVersionManagementContextPermissions() {
        #expect(PermissionCatalog.contexts.contains("VersionManagementContext"))
        // permissions(inContext:) 和 AddPermissionsUsecase 用的 allRawValues 都來自同一份 PermissionCatalog.all。
        let rawValues = Set(PermissionCatalog.permissions(inContext: "VersionManagementContext").map(\.rawValue))
        #expect(Self.frozen.subtracting(rawValues).sorted() == [])
        #expect(Self.frozen.subtracting(PermissionCatalog.allRawValues).sorted() == [])
    }

    @Test func everyVersionManagementContextPermissionHasADescriptionAndTheContextSlotOperationFormat() {
        let format = #/^VersionManagementContext\.[A-Z][A-Za-z0-9]*\.[A-Z][A-Za-z0-9]*$/#
        let infos = PermissionCatalog.permissions(inContext: "VersionManagementContext")
        #expect(!infos.isEmpty)
        for info in infos {
            #expect(info.rawValue.wholeMatch(of: format) != nil, "\(info.rawValue)")
            // console 的授權畫面顯示這段說明，管理員靠它判斷要不要授權。
            let description = info.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            #expect(!description.isEmpty, "\(info.rawValue)")
        }
    }
}
