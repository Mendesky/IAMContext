import Testing
import IAMPermissionCatalog

@Suite struct NotificationContextCatalogTests {
    static let sourceOperations = ["RegisterSource", "ReadDefinitions", "WriteDefinitions", "ExternalWriteDefinitions"]

    @Test(arguments: NotificationContextCatalogTests.sourceOperations)
    func containsOpportunitySourcePermissions(operation: String) {
        #expect(PermissionCatalog.allRawValues.contains("NotificationContext.opportunity.\(operation)"))
    }

    @Test func opportunitySlotHasExactlyTheFourOperations() {
        let raw = Set(PermissionCatalog.permissions(inContext: "NotificationContext")
            .filter { $0.slot == "opportunity" }.map(\.rawValue))
        #expect(raw == Set(Self.sourceOperations.map { "NotificationContext.opportunity.\($0)" }))
    }

    @Test(arguments: ["ListMailCcRules", "CreateMailCcRule", "GetMailCcRule", "ReplaceMailCcRule", "DeleteMailCcRule"])
    func mailCcRulePermissionsUnchanged(operation: String) {
        #expect(PermissionCatalog.allRawValues.contains("NotificationContext.MailCcRule.\(operation)"))
    }

    @Test func notificationContextSlotsAreMailCcRuleAndOpportunity() {
        let entries = PermissionCatalog.permissions(inContext: "NotificationContext")
        #expect(Set(entries.map(\.slot)) == ["MailCcRule", "opportunity"])
        #expect(entries.count == 9)
    }
}
