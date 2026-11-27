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

        let swift = try PermissionCatalogEmitter(documents: [oc, audit]).render()

        #expect(swift.contains("rawValue: \"OpportunityContext.AuditQuoting.EditAccountingType\""))
        #expect(swift.contains("rawValue: \"AuditContext.Report.SubmitReport\""))
        #expect(swift.contains("description: \"編輯帳務類型\""))
        #expect(swift.contains("description: nil"))                       // submitReport has none
        #expect(swift.contains("contexts: [String] = [\"AuditContext\", \"OpportunityContext\"]"))  // sorted
    }

    @Test func dedupsByRawValue() throws {
        let a = PermissionDocument(context: "C", serverPrefix: "", permissions: [.init(slot: "S", operationId: "x")], rules: [])
        let b = PermissionDocument(context: "C", serverPrefix: "", permissions: [.init(slot: "S", operationId: "x")], rules: [])
        let swift = try PermissionCatalogEmitter(documents: [a, b]).render()
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

    private static let typesYAML = """
    grantScopeTypes:
      - type: organization
        name: 組織
        unrestrictedKind: company
        kinds:
          - kind: company
            name: 全公司
          - kind: firms
            name: 指定所
            values: 所統編
            valuePattern: '^[0-9]{8}$'
          - kind: ownDepartment
            name: 本人的組
    """

    @Test func grantScopeParseAndEmit() throws {
        // 範圍化權限：yaml 的 grantScope 選填；有寫的進 PermissionInfo 與 grantScopes 對照表，沒寫的不進；類型定義一起產出。
        let yaml = """
        context: C
        permissions:
          - slot: S
            operationId: viewBoard
            grantScope: { type: organization, kinds: [company, firms, ownDepartment] }
          - slot: S
            operationId: plain
        """
        let doc = try PermissionDocument.load(yaml: yaml)
        #expect(doc.permissions.first { $0.operationId == "viewBoard" }?.grantScope == GrantScopeSpec(type: "organization", kinds: ["company", "firms", "ownDepartment"]))
        #expect(doc.permissions.first { $0.operationId == "plain" }?.grantScope == nil)

        let types = try GrantScopeTypesDocument.load(yaml: Self.typesYAML)
        let swift = try PermissionCatalogEmitter(documents: [doc], grantScopeTypes: types).render()
        #expect(swift.contains("rawValue: \"C.S.ViewBoard\", description: nil, grantScope: CatalogGrantScope(type: \"organization\", kinds: [\"company\", \"firms\", \"ownDepartment\"])),"))
        #expect(swift.contains("rawValue: \"C.S.Plain\", description: nil),"))   // 沒寫就不帶，跟原本的輸出一樣
        #expect(swift.contains("public static let grantScopes: [String: CatalogGrantScope]"))
        #expect(swift.contains("CatalogGrantScopeType(type: \"organization\", name: \"組織\", unrestrictedKind: \"company\", kinds: ["))
        #expect(swift.contains("CatalogGrantScopeKind(kind: \"firms\", name: \"指定所\", values: \"所統編\", valuePattern: \"^[0-9]{8}$\"),"))
        #expect(swift.contains("CatalogGrantScopeKind(kind: \"company\", name: \"全公司\", values: nil, valuePattern: nil),"))
    }

    // 沒有範圍化的權限時不用類型定義檔，產出照常（grantScopeTypes 是空的）。
    @Test func emitsEmptyGrantScopeTypesWithoutTypesFile() throws {
        let doc = PermissionDocument(context: "C", serverPrefix: "", permissions: [.init(slot: "S", operationId: "x")], rules: [])
        let swift = try PermissionCatalogEmitter(documents: [doc]).render()
        #expect(swift.contains("public static let grantScopeTypes: [CatalogGrantScopeType] = [\n    ]"))
    }

    // 權限的 grantScope 寫了不存在的類型或種類：build 失敗（不是默默少了範圍）。
    @Test func rejectsGrantScopeNotInTypes() throws {
        let types = try GrantScopeTypesDocument.load(yaml: Self.typesYAML)
        for scope in [GrantScopeSpec(type: "accountingType", kinds: ["all"]),
                      GrantScopeSpec(type: "organization", kinds: ["teams"]),
                      GrantScopeSpec(type: "organization", kinds: []),
                      GrantScopeSpec(type: "organization", kinds: ["company", "company"])] {
            let doc = PermissionDocument(context: "C", serverPrefix: "",
                                         permissions: [.init(slot: "S", operationId: "x", grantScope: scope)], rules: [])
            #expect(throws: GrantScopeCatalogError.self) { _ = try PermissionCatalogEmitter(documents: [doc], grantScopeTypes: types).render() }
        }
        // 沒有類型定義檔卻有範圍化的權限，也一樣失敗。
        let doc = PermissionDocument(context: "C", serverPrefix: "",
                                     permissions: [.init(slot: "S", operationId: "x", grantScope: GrantScopeSpec(type: "organization", kinds: ["company"]))], rules: [])
        #expect(throws: GrantScopeCatalogError.self) { _ = try PermissionCatalogEmitter(documents: [doc]).render() }
    }

    // 類型定義本身寫錯：build 失敗。
    @Test func rejectsInvalidTypeDefinitions() throws {
        let invalid = [
            // 類型重複
            "grantScopeTypes:\n  - {type: t, kinds: [{kind: a}]}\n  - {type: t, kinds: [{kind: b}]}",
            // 沒有種類
            "grantScopeTypes:\n  - {type: t, kinds: []}",
            // 種類重複
            "grantScopeTypes:\n  - {type: t, kinds: [{kind: a}, {kind: a}]}",
            // 不帶值的種類寫了格式
            "grantScopeTypes:\n  - {type: t, kinds: [{kind: a, valuePattern: 'x'}]}",
            // 格式不是合法的正規表示式
            "grantScopeTypes:\n  - {type: t, kinds: [{kind: a, values: v, valuePattern: '('}]}",
            // 不限範圍的種類不存在
            "grantScopeTypes:\n  - {type: t, unrestrictedKind: z, kinds: [{kind: a}]}",
            // 不限範圍的種類要帶值
            "grantScopeTypes:\n  - {type: t, unrestrictedKind: a, kinds: [{kind: a, values: v}]}",
        ]
        for yaml in invalid {
            let types = try GrantScopeTypesDocument.load(yaml: yaml)
            #expect(throws: GrantScopeCatalogError.self, "\(yaml)") { try types.validate() }
        }
    }

    // IAM 的類型定義檔本身要合法（build 時也會檢查，這裡讓錯誤訊息更早、更清楚）。
    @Test func iamGrantScopeTypesFileIsValid() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/IAMPermissionCatalog/grant-scope-types.yaml")
        let types = try GrantScopeTypesDocument.load(yamlPath: path.path())
        try types.validate()
        #expect(types.grantScopeTypes.map(\.type) == ["organization"])
    }

    @Test func grantScopeDoesNotAffectContextEmitter() throws {
        // 各 context 用的 PermissionEmitter 不讀 grantScope：同一份 yaml 有沒有這個欄位，輸出完全相同。
        let withScope = try PermissionDocument.load(yaml: """
        context: C
        serverPrefix: /c
        permissions:
          - slot: S
            operationId: viewBoard
            grantScope: { type: organization, kinds: [company] }
        rules:
          - method: get
            path: /board
            requires: [S.viewBoard]
        """)
        let withoutScope = try PermissionDocument.load(yaml: """
        context: C
        serverPrefix: /c
        permissions:
          - slot: S
            operationId: viewBoard
        rules:
          - method: get
            path: /board
            requires: [S.viewBoard]
        """)
        let a = try PermissionEmitter(document: withScope).render()
        let b = try PermissionEmitter(document: withoutScope).render()
        #expect(a.permissionSwift == b.permissionSwift)
        #expect(a.rulesSwift == b.rulesSwift)
    }
}
