import Testing
import Foundation
import EmployeeAccessAggregate
import IAMContextShared
import IAMPermissionCatalog

// 權限帶範圍的純函式測試（不需要 KurrentDB）：範圍解碼、寫入端檢查、重播、權限清單、事件格式相容。
// 設計：docs/discussions/2026-11-25-scoped-permission-grant.md。

private let allKinds: Set<GrantScopeKind> = Set(GrantScopeKind.allCases)

private func expectError(_ expected: EmployeeAccessError, _ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
    let error = #expect(throws: ContextError<EmployeeAccessError>.self, sourceLocation: sourceLocation) { try body() }
    #expect(error?.error == expected, sourceLocation: sourceLocation)
}

private func decodeScope(_ json: String) throws -> GrantScope {
    try JSONDecoder().decode(GrantScope.self, from: Data(json.utf8))
}

// MARK: - GrantScope 解碼（讀取端寬鬆）

@Test func grantScope_decodes_unknown_kind_without_failing() throws {
    let scope = try decodeScope(#"{"kind":"teams","teams":["x"]}"#)
    #expect(scope.kind == "teams")
    #expect(scope.knownKind == nil)
}

@Test func grantScope_decodes_malformed_fields_as_absent() throws {
    let missingKind = try decodeScope(#"{"firms":["01020314"]}"#)
    #expect(missingKind.knownKind == nil)
    let wrongType = try decodeScope(#"{"kind":"firms","firms":"01020314"}"#)
    #expect(wrongType.knownKind == .firms)
    #expect(wrongType.firms == nil)
}

@Test func grantScope_roundtrips_known_kinds() throws {
    let scopes: [GrantScope] = [.company, .ownFirm, .ownDepartment, .firms(["47575385"]),
                                .departments([.init(firm: "47575385", department: "審1")])]
    let data = try JSONEncoder().encode(scopes)
    #expect(try JSONDecoder().decode([GrantScope].self, from: data) == scopes)
}

// MARK: - 寫入端檢查（GrantScopeRules）

@Test func validatedGrant_requires_scope_for_scoped_permission() {
    expectError(.grantScopeRequired) {
        _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: [:], allowedKinds: ["p": allKinds])
    }
    expectError(.grantScopeRequired) {
        _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: ["p": []], allowedKinds: ["p": allKinds])
    }
}

@Test func validatedGrant_rejects_scope_on_unscoped_permission_and_extra_keys() {
    expectError(.grantScopeNotApplicable) {
        _ = try GrantScopeRules.validatedGrant(permissions: ["plain"], grantScopes: ["plain": [.company]], allowedKinds: [:])
    }
    expectError(.grantScopeNotApplicable) {
        _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: ["p": [.company], "other": [.company]], allowedKinds: ["p": allKinds])
    }
}

@Test func validatedGrant_rejects_kind_not_allowed() {
    expectError(.grantScopeKindNotAllowed) {
        _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: ["p": [.company]], allowedKinds: ["p": [.ownDepartment, .departments]])
    }
}

@Test func validatedGrant_rejects_invalid_scope_content() {
    let cases: [GrantScope] = [
        GrantScope(kind: "teams"),                                                  // 不認得的種類（寫入端嚴格）
        .firms([]),                                                                 // 指定所是空的
        .firms(["  "]),                                                             // 所統編空白
        GrantScope(kind: "firms", firms: ["47575385"], departments: [.init(firm: "47575385", department: "審1")]),
        .departments([]),                                                           // 指定組是空的
        .departments([.init(firm: "47575385", department: " ")]),                   // 組名空白
        .departments([.init(firm: "", department: "審1")]),                         // 所統編空白
        GrantScope(kind: "company", firms: ["47575385"]),                           // 全公司帶清單
        GrantScope(kind: "ownDepartment", departments: [.init(firm: "47575385", department: "審1")]),
    ]
    for scope in cases {
        expectError(.grantScopeInvalid) {
            _ = try GrantScopeRules.validatedGrant(permissions: ["p"], grantScopes: ["p": [scope]], allowedKinds: ["p": allKinds])
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
            .departments([.init(firm: "47575385", department: "審3 "), .init(firm: "47575385", department: "審1")]),
        ]],
        allowedKinds: ["p": allKinds]
    )
    #expect(result.keys.sorted() == ["p"])   // 不是範圍化的權限不出現在結果裡
    #expect(result["p"] == [
        .company,
        .departments([.init(firm: "47575385", department: "審1"), .init(firm: "47575385", department: "審3")]),
        .firms(["47575385", "82576039"]),
    ])
}

@Test func staticPolicy_from_catalog_ignores_unknown_kind_strings() {
    let policy = StaticGrantScopePolicy(catalog: ["p": ["company", "teams"], "q": ["ownDepartment"]])
    #expect(policy.allowedKinds(for: ["p", "q", "plain"]) == ["p": [.company], "q": [.ownDepartment]])
    #expect(policy.scopedPermissions(in: ["p", "plain"]) == ["p"])
    #expect(StaticGrantScopePolicy.none.allowedKinds(for: ["p"]).isEmpty)
}

// 權限清單上寫的 grantScopeKinds 一定都要是認得的種類（打錯字會讓權限少了允許的種類，而且不會報錯）。
@Test func catalog_grantScopeKinds_are_all_known() {
    for (permission, kinds) in PermissionCatalog.grantScopeKinds {
        #expect(!kinds.isEmpty, "\(permission) has empty grantScopeKinds")
        for kind in kinds {
            #expect(GrantScopeKind(rawValue: kind) != nil, "\(permission) has unknown grant scope kind \(kind)")
        }
    }
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

// 改範圍＝撤銷後帶新範圍授予（同一次寫入的兩筆事件）。
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

@Test func listing_skips_unknown_kinds_and_drops_empty_permissions() {
    let listing = GetPermissionGrantScopesApplicationService.listing([
        "b": [GrantScope(kind: "teams"), .company],
        "a": [GrantScope(kind: "teams")],
        "c": [.ownDepartment],
    ])
    #expect(listing == [
        PermissionGrantScopes(permission: "b", grantScopes: [.company]),
        PermissionGrantScopes(permission: "c", grantScopes: [.ownDepartment]),
    ])
}

@Test func debugOverride_returns_company_for_each_scoped_permission() {
    #expect(GetPermissionGrantScopesApplicationService.debugOverride(scopedPermissions: ["q", "p", "p"]) == [
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
