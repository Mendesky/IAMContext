import Foundation
import Testing
import IAMPermissionCatalog

/// NotificationContext 權限快照（`Sources/IAMPermissionCatalog/NotificationContext.permissions.yaml`）經 PermissionCatalogPlugin
/// 產生後的內容。不需要 KurrentDB。
///
/// 下面十三個值是 NotificationContext 1.8.0 起管理 API（`/notification-context/admin/**`）的權限，對應表在 NC 的
/// `Sources/NotificationServer/AdminPermissions.swift`。登入的使用者沒有這些權限時，NC 對應的管理操作回 403；
/// console 的 Cc 規則、通知文案、發送監控頁就會打不開。前五個（MailCcRule）沿用 NotificationContext 1.3.0 的名稱，
/// 已經授出去的不能改名。
/// 快照同步時改名或漏掉其中一個，這裡會失敗，角色就再也加不進這條權限（AddPermissions 會驗 catalog）。
/// NC 之後新增權限時，凍結值的檢查不會因為多出權限而失敗；格式和說明的檢查則套用到每一條權限（包括新增的）。
///
/// 快照和上游 SSOT 是否逐字相同，這裡不檢查（看不到上游 repo），要手動跑
/// `bash scripts/diff-permission-snapshots.sh NotificationContext`。
@Suite struct NotificationContextPermissionSnapshotTests {
    static let frozen: Set<String> = [
        "NotificationContext.MailCcRule.ListMailCcRules",
        "NotificationContext.MailCcRule.CreateMailCcRule",
        "NotificationContext.MailCcRule.GetMailCcRule",
        "NotificationContext.MailCcRule.ReplaceMailCcRule",
        "NotificationContext.MailCcRule.DeleteMailCcRule",
        "NotificationContext.Delivery.ViewDeliveries",
        "NotificationContext.Delivery.OperateDeliveries",
        "NotificationContext.Definition.ViewDefinitions",
        "NotificationContext.Definition.EditDefinitions",
        "NotificationContext.Definition.RemoveDefinition",
        "NotificationContext.Source.RegisterSource",
        "NotificationContext.FactBundle.ViewFactBundles",
        "NotificationContext.FactBundle.ExpandFactBundle",
    ]

    @Test func catalogContainsTheFrozenNotificationContextPermissions() {
        #expect(Self.frozen.count == 13)
        #expect(PermissionCatalog.contexts.contains("NotificationContext"))
        // permissions(inContext:) 和 AddPermissionsUsecase 用的 allRawValues 都來自同一份 PermissionCatalog.all。
        let rawValues = Set(PermissionCatalog.permissions(inContext: "NotificationContext").map(\.rawValue))
        #expect(Self.frozen.subtracting(rawValues).sorted() == [])
        #expect(Self.frozen.subtracting(PermissionCatalog.allRawValues).sorted() == [])
    }

    @Test func everyNotificationContextPermissionHasADescriptionAndTheContextSlotOperationFormat() {
        let format = #/^NotificationContext\.[A-Z][A-Za-z0-9]*\.[A-Z][A-Za-z0-9]*$/#
        let infos = PermissionCatalog.permissions(inContext: "NotificationContext")
        #expect(!infos.isEmpty)
        for info in infos {
            #expect(info.rawValue.wholeMatch(of: format) != nil, "\(info.rawValue)")
            // console 的授權畫面顯示這段說明，管理員靠它判斷要不要授權。
            let description = info.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            #expect(!description.isEmpty, "\(info.rawValue)")
        }
    }
}
