import Testing
import Foundation
import EmployeeAccessAggregate
import IAMContextShared
import IAMPermissionCatalog
@testable import IAMContextServer

// 權限帶範圍的純函式測試（不需要 KurrentDB）：範圍解碼、寫入端檢查、重播、權限清單、事件格式相容。
// 設計：docs/discussions/2026-11-25-scoped-permission-grant.md。

private let organization = OrganizationScope.rule()

private func expectError(_ expected: EmployeeAccessError, _ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
    let error = #expect(throws: ContextError<EmployeeAccessError>.self, sourceLocation: sourceLocation) { try body() }
    #expect(error?.error == expected, sourceLocation: sourceLocation)
}

private func decodeScope(_ json: String) throws -> GrantScope {
    try JSONDecoder().decode(GrantScope.self, from: Data(json.utf8))
}

// MARK: - GrantScope 解碼（讀取端寬鬆）

@Test func grantScope_decodes_unknown_type_and_kind_without_failing() throws {
    let scope = try decodeScope(#"{"type":"accountingType","kind":"specified","values":["稅務帳"],"extra":1}"#)
    #expect(scope == GrantScope(type: "accountingType", kind: "specified", values: ["稅務帳"]))
    #expect(scope.isComplete)
}

@Test func grantScope_decodes_malformed_fields_as_absent() throws {
    let wrongValues = try decodeScope(#"{"type":"organization","kind":"firms","values":"01020314"}"#)
    #expect(wrongValues.values == nil)
    #expect(wrongValues.isComplete)
    let missingKind = try decodeScope(#"{"type":"organization","values":["01020314"]}"#)
    #expect(!missingKind.isComplete)
}

// 2026-11-27 改格式前（.55 的 1.11.0-beta.0 寫過）的 {kind, firms}：解得開，但沒有類型，讀取端略過。
@Test func grantScope_decodes_pre_type_format_as_incomplete() throws {
    let old = try decodeScope(#"{"kind":"firms","firms":["47575385"]}"#)
    #expect(old.kind == "firms")
    #expect(old.type.isEmpty)
    #expect(old.values == nil)
    #expect(!old.isComplete)
}

@Test func grantScope_roundtrips() throws {
    let scopes: [GrantScope] = [.company, .ownFirm, .ownDepartment, .firms(["47575385"]), .departments(["47575385/審1"])]
    let data = try JSONEncoder().encode(scopes)
    #expect(try JSONDecoder().decode([GrantScope].self, from: data) == scopes)
}

// MARK: - 寫入端檢查（GrantScopeRules）

@Test func validatedGrant_requires_scope_for_scoped_permission() {
    expectError(.grantScopeRequired) {
        _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: [:], rules: ["p": organization])
    }
    expectError(.grantScopeRequired) {
        _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: ["p": []], rules: ["p": organization])
    }
}

@Test func validatedGrant_rejects_scope_on_unscoped_permission_and_extra_keys() {
    expectError(.grantScopeNotApplicable) {
        _ = try GrantScopeRules.validatedGrant(permissions: ["plain"], grantScopes: ["plain": [.company]], rules: [:])
    }
    expectError(.grantScopeNotApplicable) {
        _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: ["p": [.company], "other": [.company]], rules: ["p": organization])
    }
}

@Test func validatedGrant_rejects_kind_not_allowed() {
    expectError(.grantScopeKindNotAllowed) {
        _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: ["p": [.company]],
                                               rules: ["p": OrganizationScope.rule(["ownDepartment", "departments"])])
    }
}

// 類型要是這個權限的類型：別的類型（包括沒有類型的舊格式）一律拒絕。
@Test func validatedGrant_rejects_other_type() {
    for scope in [GrantScope(type: "accountingType", kind: "company"), GrantScope(type: "", kind: "company")] {
        expectError(.grantScopeKindNotAllowed) {
            _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: ["p": [scope]], rules: ["p": organization])
        }
    }
}

@Test func validatedGrant_rejects_invalid_scope_content() {
    let cases: [GrantScope] = [
        GrantScope(type: "organization", kind: "teams"),                          // 類型底下沒有的種類（寫入端嚴格）
        .firms([]),                                                                 // 指定所是空的
        GrantScope(type: "organization", kind: "firms"),                            // 指定所沒帶值
        .firms(["  "]),                                                             // 所統編空白
        .firms(["台中所"]),                                                          // 所別名稱不是統編
        .firms(["4757538"]),                                                        // 少一碼
        .firms(["475753851"]),                                                      // 多一碼
        .firms(["４７５７５３８５"]),                                                  // 全形數字
        .departments(["台中所/審1"]),                                                // 指定組的所不是統編
        .departments(["47575385"]),                                                 // 指定組沒有組名
        .departments(["47575385/"]),                                                // 組名空的
        .departments(["47575385/ 審1"]),                                            // 組名前面有空白
        .departments(["47575385/　"]),                                              // 組名是全形空白
        .departments([]),                                                           // 指定組是空的
        .departments(["/審1"]),                                                     // 所統編空白
        GrantScope(type: "organization", kind: "company", values: ["47575385"]),   // 全公司帶值
        GrantScope(type: "organization", kind: "ownDepartment", values: ["47575385/審1"]),
    ]
    for scope in cases {
        expectError(.grantScopeInvalid) {
            _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: ["p": [scope]], rules: ["p": organization])
        }
    }
}

@Test func validatedGrant_normalizes_trims_dedups_and_sorts() throws {
    let result = try GrantScopeRules.validatedGrant(
        permissions: ["p", "plain"],
        grantScopes: ["p": [
            .firms([" 82576039", "47575385", "82576039"]),
            .company,
            .company,
            .departments(["47575385/審3 ", "47575385/審1"]),
            GrantScope(type: "organization", kind: "ownFirm", values: []),        // 不帶值的種類給空清單也可以，存成 nil
        ]],
        rules: ["p": organization]
    )
    #expect(result.keys.sorted() == ["p"])   // 不是範圍化的權限不出現在結果裡
    #expect(result["p"] == [
        .company,
        .departments(["47575385/審1", "47575385/審3"]),
        .firms(["47575385", "82576039"]),
        .ownFirm,
    ])
}

// 類型定義是資料：換一個測試用的類型，同一套檢查照樣能用（以後加類型不用改 GrantScopeRules）。
@Test func validated_works_for_any_type_definition() throws {
    let accountingType = GrantScopeTypeDefinition(type: "accountingType", unrestrictedKind: "all", kinds: [
        GrantScopeKindDefinition(kind: "all", takesValues: false),
        GrantScopeKindDefinition(kind: "specified", takesValues: true, valuePattern: "(tax|finance)"),
    ])
    let rule = GrantScopeRule(type: accountingType, allowedKinds: ["all", "specified"])
    let result = try GrantScopeRules.validated(
        [GrantScope(type: "accountingType", kind: "specified", values: ["tax", "finance", "tax"])], rule: rule, permission: "p")
    #expect(result == [GrantScope(type: "accountingType", kind: "specified", values: ["finance", "tax"])])
    expectError(.grantScopeInvalid) {
        _ = try GrantScopeRules.validated([GrantScope(type: "accountingType", kind: "specified", values: ["taxes"])], rule: rule, permission: "p")
    }
    expectError(.grantScopeKindNotAllowed) {
        _ = try GrantScopeRules.validated([.company], rule: rule, permission: "p")
    }
}

// MARK: - 權限清單 → 範圍規則

@Test func staticPolicy_from_catalog_ignores_unknown_types_and_kinds() {
    let policy = StaticGrantScopePolicy(types: [OrganizationScope.type], permissions: [
        "p": (type: "organization", kinds: ["company", "teams"]),
        "q": (type: "accountingType", kinds: ["all"]),
        "r": (type: "organization", kinds: ["ownDepartment"]),
    ])
    #expect(policy.rules(for: ["p", "q", "r", "plain"]) == [
        "p": OrganizationScope.rule(["company"]),
        "r": OrganizationScope.rule(["ownDepartment"]),
    ])
    #expect(policy.scopedPermissions(in: ["p", "plain"]) == ["p"])
    #expect(StaticGrantScopePolicy.none.rules(for: ["p"]).isEmpty)
}

// 權限清單的類型定義：組織類型的五個種類、不限範圍是全公司；指定所、指定組帶值。
@Test func catalog_defines_organization_type() {
    let type = OrganizationScope.type
    #expect(Set(type.kinds.keys) == ["company", "firms", "departments", "ownFirm", "ownDepartment"])
    #expect(type.unrestrictedKind == "company")
    #expect(type.kinds.values.filter(\.takesValues).map(\.kind).sorted() == ["departments", "firms"])
}

// 權限清單上每個範圍化的權限，類型與種類都對得上類型定義（build 時 permission-catalog-gen 也會檢查）。
@Test func catalog_grantScopes_all_resolve() {
    let rules = GrantScopeCatalog.policy.rulesByPermission
    #expect(Set(rules.keys) == Set(PermissionCatalog.grantScopes.keys))
    for (permission, scope) in PermissionCatalog.grantScopes {
        #expect(rules[permission]?.allowedKinds == Set(scope.kinds), "\(permission) has kinds not in type \(scope.type)")
    }
}

// 第一個範圍化的權限：管理者看板（OC 權限清單逐字複製進來）。組織類型、五種範圍都允許。
@Test func managerDashboard_permission_is_scoped_with_all_organization_kinds() {
    let permission = "OpportunityContext.ManagerDashboard.ViewQuotingCases"
    #expect(PermissionCatalog.allRawValues.contains(permission))
    #expect(PermissionCatalog.grantScopes[permission]?.type == "organization")
    #expect(GrantScopeCatalog.policy.rules(for: [permission]) == [permission: OrganizationScope.rule()])
}

// MARK: - 重播（PermissionTimeline.replayAccess）

private func entry(_ commit: UInt64, _ event: TimelineEvent) -> TimelineEntry {
    TimelineEntry(position: LogPosition(commit: commit, prepare: commit), event: event)
}

@Test func replay_records_scopes_from_grants_and_drops_them_on_revoke() {
    let scopes: [String: [GrantScope]] = ["p": [.firms(["47575385"])]]
    let granted = PermissionTimeline.replayAccess([
        entry(1, .profileCreated(permissions: [], roles: [])),
        entry(2, .privilegeGranted(permissions: ["p", "plain"], grantScopes: scopes)),
    ])
    #expect(granted.permissions == ["p", "plain"])
    #expect(granted.grantScopes == scopes)

    let revoked = PermissionTimeline.replayAccess([
        entry(1, .profileCreated(permissions: [], roles: [])),
        entry(2, .privilegeGranted(permissions: ["p"], grantScopes: scopes)),
        entry(3, .privilegeRevoked(permissions: ["p"])),
    ])
    #expect(revoked.permissions.isEmpty)
    #expect(revoked.grantScopes.isEmpty)
}

// 撤銷後帶新範圍授予：範圍換成新的。
@Test func replay_change_scope_replaces_scopes() {
    let access = PermissionTimeline.replayAccess([
        entry(1, .profileCreated(permissions: [], roles: [])),
        entry(2, .privilegeGranted(permissions: ["p"], grantScopes: ["p": [.ownDepartment]])),
        entry(3, .privilegeRevoked(permissions: ["p"])),
        entry(4, .privilegeGranted(permissions: ["p"], grantScopes: ["p": [.firms(["47575385", "82576039"])]])),
    ])
    #expect(access.permissions == ["p"])
    #expect(access.grantScopes == ["p": [.firms(["47575385", "82576039"])]])
}

// 改範圍事件：權限有效時換範圍、不改有效權限；權限已不是有效權限時不理。
@Test func replay_scope_changed_event_replaces_scopes_only_for_effective_permission() {
    let changed = PermissionTimeline.replayAccess([
        entry(1, .profileCreated(permissions: [], roles: [])),
        entry(2, .privilegeGranted(permissions: ["p"], grantScopes: ["p": [.ownDepartment]])),
        entry(3, .privilegeScopeChanged(permission: "p", grantScopes: [.firms(["47575385"])])),
    ])
    #expect(changed.permissions == ["p"])
    #expect(changed.grantScopes == ["p": [.firms(["47575385"])]])

    let notHeld = PermissionTimeline.replayAccess([
        entry(1, .profileCreated(permissions: [], roles: [])),
        entry(2, .privilegeGranted(permissions: ["p"], grantScopes: ["p": [.ownDepartment]])),
        entry(3, .privilegeRevoked(permissions: ["p"])),
        entry(4, .privilegeScopeChanged(permission: "p", grantScopes: [.company])),
    ])
    #expect(notHeld.permissions.isEmpty)
    #expect(notHeld.grantScopes.isEmpty)
}

// 舊事件（沒有 grantScopes）：權限照常有效，但沒有範圍。
@Test func replay_old_grant_without_scopes_has_no_scope() {
    let access = PermissionTimeline.replayAccess([
        entry(1, .profileCreated(permissions: [], roles: [])),
        entry(2, .privilegeGranted(permissions: ["p"])),
    ])
    #expect(access.permissions == ["p"])
    #expect(access.grantScopes.isEmpty)
}

@Test func replay_profile_recreated_resets_scopes() {
    let access = PermissionTimeline.replayAccess([
        entry(1, .profileCreated(permissions: [], roles: [])),
        entry(2, .privilegeGranted(permissions: ["p"], grantScopes: ["p": [.company]])),
        entry(3, .profileCreated(permissions: ["p"], roles: [])),
    ])
    #expect(access.permissions == ["p"])
    #expect(access.grantScopes.isEmpty)
}

// 撤銷角色把權限從有效權限拿掉時，範圍也不留（最後只保留仍有效的權限的範圍）。
@Test func replay_keeps_scopes_only_for_effective_permissions() {
    let access = PermissionTimeline.replayAccess([
        entry(1, .roleCreated(roleId: "r")),
        entry(2, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(3, .profileCreated(permissions: [], roles: ["r"])),
        entry(4, .privilegeGranted(permissions: ["p"], grantScopes: ["p": [.company]])),
        entry(5, .rolesRevoked(roleIds: ["r"])),
    ])
    #expect(access.permissions == PermissionTimeline.replay([
        entry(1, .roleCreated(roleId: "r")),
        entry(2, .rolePermissionsAdded(roleId: "r", permissions: ["p"])),
        entry(3, .profileCreated(permissions: [], roles: ["r"])),
        entry(4, .privilegeGranted(permissions: ["p"])),
        entry(5, .rolesRevoked(roleIds: ["r"])),
    ]))
    #expect(Set(access.grantScopes.keys).isSubset(of: access.permissions))
}

// MARK: - 查詢的清單（略過不認得的種類）

@Test func listing_skips_incomplete_items_and_drops_empty_permissions() {
    let listing = GetPermissionGrantScopesApplicationService.listing([
        "b": [GrantScope(type: "", kind: "firms"), .company],
        "a": [GrantScope(type: "organization", kind: "")],
        "c": [.ownDepartment],
        "d": [GrantScope(type: "accountingType", kind: "all")],   // 不認得的類型照樣回，由呼叫端略過
    ])
    #expect(listing == [
        PermissionGrantScopes(permission: "b", grantScopes: [.company]),
        PermissionGrantScopes(permission: "c", grantScopes: [.ownDepartment]),
        PermissionGrantScopes(permission: "d", grantScopes: [GrantScope(type: "accountingType", kind: "all")]),
    ])
}

@Test func debugOverride_returns_unrestricted_kind_for_each_scoped_permission() {
    let noUnrestricted = GrantScopeTypeDefinition(type: "t", kinds: [GrantScopeKindDefinition(kind: "k", takesValues: false)])
    #expect(GetPermissionGrantScopesApplicationService.debugOverride(rules: [
        "q": OrganizationScope.rule(["ownDepartment"]),
        "p": OrganizationScope.rule(),
        "r": GrantScopeRule(type: noUnrestricted, allowedKinds: ["k"]),   // 類型沒有不限範圍種類：不列
    ]) == [
        PermissionGrantScopes(permission: "p", grantScopes: [.company]),
        PermissionGrantScopes(permission: "q", grantScopes: [.company]),
    ])
}

// MARK: - 事件格式相容（退版）

/// 1.8.0 的 PrivilegeGranted 形狀（沒有 grantScopes）：用來確認舊版 IAM 解得開新事件（多出來的欄位略過）。
private struct PrivilegeGrantedBeforeGrantScopes: Decodable {
    let id: UUID
    let employeeAccessId: String
    let userId: String
    let permissions: [String]
    let occurred: Date
}

@Test func new_event_decodes_with_old_shape_and_old_event_decodes_with_new_shape() throws {
    let withScopes = PrivilegeGranted(employeeAccessId: "ea", userId: "u", permissions: ["p"],
                                      grantScopes: ["p": [.firms(["47575385"])]], occurred: .now)
    let newJSON = try JSONEncoder().encode(withScopes)
    let old = try JSONDecoder().decode(PrivilegeGrantedBeforeGrantScopes.self, from: newJSON)
    #expect(old.permissions == ["p"])

    let withoutScopes = PrivilegeGranted(employeeAccessId: "ea", userId: "u", permissions: ["p"], grantScopes: nil, occurred: .now)
    let oldJSON = try JSONEncoder().encode(withoutScopes)
    let object = try #require(try JSONSerialization.jsonObject(with: oldJSON) as? [String: Any])
    #expect(object["grantScopes"] == nil)   // 沒有範圍時不寫這個 key，跟舊事件一樣
    #expect(try JSONDecoder().decode(PrivilegeGranted.self, from: oldJSON).grantScopes == nil)
}
