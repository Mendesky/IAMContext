import Foundation
import Testing
import IAMPermissionCatalog

/// 已退役、從目錄拿掉的權限。不需要 KurrentDB。
///
/// VersionManagementContext 的三條應用程式憑證權限：VMC 1.5.0 拆掉了檢查它們的路由，系統憑證改由 OIDCContext admin
/// 管理（權限 `OIDCContext.ApplicationCredential.*`）。目錄裡留著它們，管理者會以為授權了有用。
/// 這裡確認它們不會因為舊分支合併或重新同步快照又回到目錄：角色加權限（AddPermissions）只接受目錄裡的權限，console 的
/// 授權畫面也只列目錄裡的權限。個人授權（GrantPrivilege）本來就不檢查目錄（既有行為，這裡不改）。
/// 已經授權的值不受影響：IAM 的 RevokePrivilege（個人）和 RemovePermissions（角色）都不檢查目錄，API 仍然可以移除；
/// 只是 console 重新產生目錄之後，就沒有這三條的名稱和說明可以挑選。
@Suite struct RetiredPermissionsTests {
    static let retired: Set<String> = [
        "VersionManagementContext.Product.GetProductApplication",
        "VersionManagementContext.Product.CreateProductCredential",
        "VersionManagementContext.Product.RegenerateProductCredentialSecret",
    ]

    @Test func retiredVersionManagementContextPermissionsAreNotInTheCatalog() {
        #expect(Self.retired.intersection(PermissionCatalog.allRawValues).sorted() == [])
        #expect(!PermissionCatalog.contexts.contains("VersionManagementContext"))
    }
}
