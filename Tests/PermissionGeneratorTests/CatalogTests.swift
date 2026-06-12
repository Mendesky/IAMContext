import Testing
import Foundation
@testable import PermissionGenerator

/// Tests for the aggregation path (PermissionCatalogEmitter): many context documents → one
/// enumerable cross-context catalog. Used by an aggregator like IAM (role design + granting UI).
struct CatalogTests {

    @Test func aggregatesMultipleContexts() throws {
        let oc = PermissionDocument(
            context: "OpportunityContext", serverPrefix: "/opportunity-context",
            permissions: [.init(slot: "AuditQuoting", operationId: "editAccountingType", description: "編輯帳務類型")],
            rules: [])
        let audit = PermissionDocument(
            context: "AuditContext", serverPrefix: "/audit",
            permissions: [.init(slot: "Report", operationId: "submitReport")],
            rules: [])

        let swift = PermissionCatalogEmitter(documents: [oc, audit]).render()

        #expect(swift.contains("rawValue: \"OpportunityContext.AuditQuoting.EditAccountingType\""))
        #expect(swift.contains("rawValue: \"AuditContext.Report.SubmitReport\""))
        #expect(swift.contains("description: \"編輯帳務類型\""))
        #expect(swift.contains("description: nil"))                       // submitReport has none
        #expect(swift.contains("contexts: [String] = [\"AuditContext\", \"OpportunityContext\"]"))  // sorted
    }

    @Test func dedupsByRawValue() throws {
        let a = PermissionDocument(context: "C", serverPrefix: "", permissions: [.init(slot: "S", operationId: "x")], rules: [])
        let b = PermissionDocument(context: "C", serverPrefix: "", permissions: [.init(slot: "S", operationId: "x")], rules: [])
        let swift = PermissionCatalogEmitter(documents: [a, b]).render()
        let count = swift.components(separatedBy: "rawValue: \"C.S.X\"").count - 1
        #expect(count == 1)
    }

    @Test func catalogOnlyYamlParses() throws {
        // No `rules:` key — lenient decoding should still load (rules default to []).
        let yaml = """
        context: C
        permissions:
          - slot: S
            operationId: doThing
        """
        let doc = try PermissionDocument.load(yaml: yaml)
        #expect(doc.rules.isEmpty)
        #expect(doc.permissions.count == 1)
        #expect(doc.serverPrefix == "")
    }
}
