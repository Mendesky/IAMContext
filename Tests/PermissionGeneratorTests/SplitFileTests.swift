import Testing
import Foundation
@testable import PermissionGenerator

/// The two-file (split) layout: a catalog file (`<Context>.permissions.yaml`) + a rules file
/// (`<Context>.rules.yaml`) merge back into one `PermissionDocument`. The point of merging into one
/// document is that the existing emitter validation — crucially the dangling-`requires` check — then
/// covers CROSS-FILE references for free. These tests pin that, the consistency guards, and the
/// `--all` split round-trip.
struct SplitFileTests {

    @Test func mergeCombinesCatalogAndRules() throws {
        let catalog = """
        context: OpportunityContext
        serverPrefix: /opportunity-context
        permissions:
          - slot: AuditQuoting
            operationId: editAccountingType
          - slot: Workflow
            operationId: closeDeal
        """
        let rules = """
        rules:
          - method: patch
            path: /audit-quotings/{id}/accounting-type
            requires: [AuditQuoting.editAccountingType]
          - method: post
            path: /audit-quotings/{id}/close
            requires: [Workflow.closeDeal]
        """
        let doc = try PermissionDocument.merge(permissionsYAML: catalog, rulesYAML: rules)
        #expect(doc.context == "OpportunityContext")
        #expect(doc.serverPrefix == "/opportunity-context")
        #expect(doc.permissions.count == 2)
        #expect(doc.rules.count == 2)
        _ = try PermissionEmitter(document: doc).render()  // renders without error
    }

    /// The biggest correctness risk of splitting: a rule in one file referencing a permission in the
    /// other. After merge, the existing dangling-reference check must still catch it.
    @Test func crossFileDanglingReferenceThrows() throws {
        let catalog = """
        context: C
        permissions:
          - slot: A
            operationId: x
        """
        let rules = """
        rules:
          - method: get
            path: /y
            requires: [A.notThere]
        """
        let doc = try PermissionDocument.merge(permissionsYAML: catalog, rulesYAML: rules)
        #expect(throws: GeneratorError.self) {
            _ = try PermissionEmitter(document: doc).render()
        }
    }

    @Test func catalogFileWithInlineRulesThrows() throws {
        let catalog = """
        context: C
        permissions:
          - slot: A
            operationId: x
        rules:
          - method: get
            path: /x
            requires: [A.x]
        """
        #expect(throws: DocumentError.self) {
            _ = try PermissionDocument.merge(permissionsYAML: catalog, rulesYAML: "rules: []")
        }
    }

    @Test func contextMismatchThrows() throws {
        let catalog = """
        context: C
        permissions:
          - slot: A
            operationId: x
        """
        let rules = """
        context: D
        rules:
          - method: get
            path: /x
            requires: [A.x]
        """
        #expect(throws: DocumentError.self) {
            _ = try PermissionDocument.merge(permissionsYAML: catalog, rulesYAML: rules)
        }
    }

    @Test func serverPrefixMismatchThrows() throws {
        let catalog = """
        context: C
        serverPrefix: /c
        permissions:
          - slot: A
            operationId: x
        """
        let rules = """
        serverPrefix: /different
        rules: []
        """
        #expect(throws: DocumentError.self) {
            _ = try PermissionDocument.merge(permissionsYAML: catalog, rulesYAML: rules)
        }
    }

    /// `permission-gen --all`: a combined document splits into two files, and merging them back is
    /// semantically identical (same rendered Swift).
    @Test func splitRoundTrips() throws {
        let combined = PermissionDocument(
            context: "OpportunityContext", serverPrefix: "/opportunity-context",
            permissions: [
                .init(slot: "AuditQuoting", operationId: "editAccountingType", description: "編輯帳務類型"),
                .init(slot: "Workflow", operationId: "closeDeal"),
            ],
            rules: [
                .init(method: "patch", path: "/audit-quotings/{id}/accounting-type", requires: ["AuditQuoting.editAccountingType"]),
                .init(method: "post", path: "/x/close", requires: ["Workflow.closeDeal"]),
            ])

        let (permYAML, rulesYAML) = try combined.splitYAML()
        let back = try PermissionDocument.merge(permissionsYAML: permYAML, rulesYAML: rulesYAML)

        #expect(back.context == combined.context)
        #expect(back.serverPrefix == combined.serverPrefix)
        #expect(back.permissions.count == combined.permissions.count)
        #expect(back.rules.count == combined.rules.count)

        let a = try PermissionEmitter(document: combined).render()
        let b = try PermissionEmitter(document: back).render()
        #expect(a.permissionSwift == b.permissionSwift)
        #expect(a.rulesSwift == b.rulesSwift)
    }
}
