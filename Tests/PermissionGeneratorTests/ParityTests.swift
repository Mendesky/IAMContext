import Testing
import Foundation
@testable import PermissionGenerator

/// Acceptance: generating from the SPLIT (Option B) YAML must reproduce OpportunityContext's existing
/// 153 permissions and 153 rules *semantically* (set equality of permission rawValues and of
/// (pathRegex, method, sorted-required-consts) rule tuples). Plus: the new capabilities Option B
/// unlocks (AND-multiple, shared permission, catalog-only) and its guard (dangling reference).
struct ParityTests {

    // MARK: - fixtures

    private func fixture(_ fileName: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: fileName, withExtension: nil, subdirectory: "Fixtures"),
            "missing fixture \(fileName)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func document() throws -> PermissionDocument {
        try PermissionDocument.load(yaml: try fixture("OpportunityContext.permissions.yaml"))
    }

    // MARK: - extractors (work on both generated output and the OC snapshots)

    private func permissionRawValues(_ swift: String) -> Set<String> {
        let re = try! Regex(#"Permission\("([^"]+)"\)"#)
        return Set(swift.matches(of: re).compactMap { $0.output[1].substring.map(String.init) })
    }

    /// (pathRegex, method, sorted required consts joined by "+") — handles single OR multiple requires.
    private func ruleTuples(_ swift: String) -> Set<[String]> {
        let ruleRe = try! Regex(##"PathValidator\(try Regex\(#"([^"]+)"#\)\), methods: \[\.(\w+)\], requires: \[([^\]]*)\]"##)
        let constRe = try! Regex(#"Permission\.(\w+)\.rawValue"#)
        return Set(swift.matches(of: ruleRe).map { m in
            let regex = String(m.output[1].substring ?? "")
            let method = String(m.output[2].substring ?? "")
            let inner = String(m.output[3].substring ?? "")
            let consts = inner.matches(of: constRe).compactMap { $0.output[1].substring.map(String.init) }.sorted()
            return [regex, method, consts.joined(separator: "+")]
        })
    }

    // MARK: - parity with OpportunityContext

    @Test func generatedPermissionSetMatchesOC() throws {
        let out = try PermissionEmitter(document: document()).render()
        let mine = permissionRawValues(out.permissionSwift)
        let oc = permissionRawValues(try fixture("oc-Permission.swift.snapshot"))

        #expect(oc.count == 153)
        #expect(mine.count == 153)
        #expect(mine.subtracting(oc).isEmpty, "extra permissions in generated: \(mine.subtracting(oc).sorted())")
        #expect(oc.subtracting(mine).isEmpty, "permissions missing from generated: \(oc.subtracting(mine).sorted())")
    }

    @Test func generatedRuleSetMatchesOC() throws {
        let out = try PermissionEmitter(document: document()).render()
        let mine = ruleTuples(out.rulesSwift)
        let oc = ruleTuples(try fixture("oc-PermissionRules.swift.snapshot"))

        #expect(oc.count == 153)
        #expect(mine.count == 153)
        #expect(mine.subtracting(oc).isEmpty, "extra rules in generated: \(mine.subtracting(oc).sorted { $0[0] < $1[0] })")
        #expect(oc.subtracting(mine).isEmpty, "rules missing from generated: \(oc.subtracting(mine).sorted { $0[0] < $1[0] })")
    }

    // MARK: - unit: naming & regex

    @Test func namingAndPathRegex() throws {
        let e = PermissionEmitter(document: PermissionDocument(
            context: "OpportunityContext", serverPrefix: "/opportunity-context", permissions: [], rules: []))
        #expect(e.constName(slot: "AuditQuoting", operationId: "editAccountingType") == "auditQuotingEditAccountingType")
        #expect(e.rawValue(slot: "AuditQuoting", operationId: "editAccountingType") == "OpportunityContext.AuditQuoting.EditAccountingType")
        #expect(e.pathRegex("/audit-quotings/{quotingId}/accounting-type") == "/opportunity-context/audit-quotings/[^/]+/accounting-type")
    }

    @Test func rejectsInvalidMethod() throws {
        let doc = PermissionDocument(context: "C", serverPrefix: "/c",
            permissions: [.init(slot: "Query", operationId: "getX")],
            rules: [.init(method: "fetch", path: "/x", requires: ["Query.getX"])])
        #expect(throws: GeneratorError.self) {
            _ = try PermissionEmitter(document: doc).render()
        }
    }

    // MARK: - Option B capabilities

    @Test func ruleCanRequireMultiplePermissionsAND() throws {
        let doc = PermissionDocument(context: "OC", serverPrefix: "",
            permissions: [.init(slot: "A", operationId: "x"), .init(slot: "B", operationId: "y")],
            rules: [.init(method: "post", path: "/z", requires: ["A.x", "B.y"])])
        let out = try PermissionEmitter(document: doc).render()
        #expect(out.rulesSwift.contains("requires: [Permission.aX.rawValue, Permission.bY.rawValue]"))
    }

    @Test func multipleRulesCanShareOnePermission() throws {
        let doc = PermissionDocument(context: "OC", serverPrefix: "",
            permissions: [.init(slot: "W", operationId: "close")],
            rules: [
                .init(method: "post", path: "/a/close", requires: ["W.close"]),
                .init(method: "post", path: "/b/close", requires: ["W.close"]),
            ])
        let out = try PermissionEmitter(document: doc).render()
        #expect(permissionRawValues(out.permissionSwift).count == 1)
        let references = out.rulesSwift.components(separatedBy: "Permission.wClose.rawValue").count - 1
        #expect(references == 2)
    }

    @Test func allowsCatalogOnlyPermission() throws {
        let doc = PermissionDocument(context: "OC", serverPrefix: "",
            permissions: [.init(slot: "A", operationId: "x"), .init(slot: "A", operationId: "unusedPerm")],
            rules: [.init(method: "get", path: "/y", requires: ["A.x"])])
        let out = try PermissionEmitter(document: doc).render()
        #expect(permissionRawValues(out.permissionSwift).count == 2)
        #expect(out.rulesSwift.contains("Permission.aX.rawValue"))
        #expect(!out.rulesSwift.contains("aUnusedPerm"))
    }

    @Test func rejectsDanglingReference() throws {
        let doc = PermissionDocument(context: "OC", serverPrefix: "",
            permissions: [.init(slot: "A", operationId: "x")],
            rules: [.init(method: "get", path: "/y", requires: ["A.notThere"])])
        #expect(throws: GeneratorError.self) {
            _ = try PermissionEmitter(document: doc).render()
        }
    }
}
