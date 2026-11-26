import Testing
import Foundation
import DDDKit
import KurrentDB
import TestUtility
import GRPCCore
import Generated
import EmployeeAccessAggregate
import RoleAggregate
import IAMContextShared
import IAMPermissionCatalog
@testable import IAMContextServer

// 權限帶範圍的整合測試（需要 KurrentDB；用 ESDB_TEST_URL 指到測試用的 DB）。
// 設計：docs/discussions/2026-11-25-scoped-permission-grant.md。
// 權限清單現在還沒有範圍化的權限，所以用自己的 GrantScopePolicy 把測試權限標成範圍化。
// 寫入結果用員工原始 stream 重播檢查（effectiveAccess，強一致、不經 projection）；以 userId 查詢的那幾條
// 需要 IAM_GetPermissions projection（CI 有部署），比照 RolePermissionCompositionIntegrationTests 等一下再讀。
@Suite(.serialized)
struct GrantScopeIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let repository: EmployeeAccessRepository

    static let view = "Test.Scoped.View"
    static let group = "Test.Scoped.Group"
    static let plain = "custom:plain"
    static let policy = StaticGrantScopePolicy([
        view: Set(GrantScopeKind.allCases),
        group: [.ownDepartment, .departments],
    ])

    init() {
        self.repository = EmployeeAccessRepository(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
    }

    private var timeline: PermissionTimelineService {
        PermissionTimelineService(kdbClient: kdbClient, roleDirectory: FakeRoleDirectory())
    }

    private func handler(policy: StaticGrantScopePolicy = Self.policy, directory: any RoleDirectory = FakeRoleDirectory()) -> EmployeeAccessAggregate.ApiHandler {
        EmployeeAccessAggregate.ApiHandler(kdbClient: kdbClient, roleDirectory: directory, grantScopePolicy: policy)
    }

    private func dto(_ scopes: [GrantScope]) -> [EmployeeAccessAggregate.Components.Schemas.GrantScope] {
        scopes.map(EmployeeAccessAggregate.Components.Schemas.GrantScope.init(domain:))
    }

    private func grant(
        _ handler: EmployeeAccessAggregate.ApiHandler,
        employeeAccessId: String, userId: String, operatorId: String,
        permissions: [String], grantScopes: [String: [GrantScope]]? = nil
    ) async throws -> EmployeeAccessAggregate.Operations.grantPrivilege.Output {
        try await handler.grantPrivilege(.init(
            path: .init(employeeAccessId: employeeAccessId),
            headers: .init(operatorId: operatorId),
            body: .json(.init(
                userId: userId,
                permissions: permissions,
                grantScopes: grantScopes.map { .init(additionalProperties: $0.mapValues(dto)) }
            ))
        ))
    }

    private func change(
        _ handler: EmployeeAccessAggregate.ApiHandler,
        employeeAccessId: String, userId: String, operatorId: String,
        permission: String, grantScopes: [GrantScope]
    ) async throws -> EmployeeAccessAggregate.Operations.changeGrantScope.Output {
        try await handler.changeGrantScope(.init(
            path: .init(employeeAccessId: employeeAccessId),
            headers: .init(operatorId: operatorId),
            body: .json(.init(userId: userId, permission: permission, grantScopes: dto(grantScopes)))
        ))
    }

    private func expect422(_ output: EmployeeAccessAggregate.Operations.grantPrivilege.Output, _ expected: EmployeeAccessAggregate.Components.Schemas.EmployeeAccessApiError, sourceLocation: SourceLocation = #_sourceLocation) throws {
        guard case .unprocessableContent(let response) = output else {
            Issue.record("expected 422 \(expected), got \(output)", sourceLocation: sourceLocation)
            return
        }
        #expect(try response.body.json.error == expected, sourceLocation: sourceLocation)
    }

    private func expect422(_ output: EmployeeAccessAggregate.Operations.changeGrantScope.Output, _ expected: EmployeeAccessAggregate.Components.Schemas.EmployeeAccessApiError, sourceLocation: SourceLocation = #_sourceLocation) throws {
        guard case .unprocessableContent(let response) = output else {
            Issue.record("expected 422 \(expected), got \(output)", sourceLocation: sourceLocation)
            return
        }
        #expect(try response.body.json.error == expected, sourceLocation: sourceLocation)
    }

    /// 員工原始 stream 的事件型別（依寫入順序）。
    private func eventTypes(employeeAccessId: String) async throws -> [String] {
        var types: [String] = []
        let responses = try await kdbClient.streams(specified: EmployeeAccess.getStreamName(id: employeeAccessId)).read()
        for try await response in responses {
            if case let .event(readEvent) = response { types.append(readEvent.record.eventType) }
        }
        return types
    }

    private func waitForProjection() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    // MARK: - 授權帶範圍

    @Test func grant_scoped_permission_records_normalized_scopes() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let op = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: eaId, userId: userId, operatorId: op, repository: repository)

            let output = try await grant(handler(), employeeAccessId: eaId, userId: userId, operatorId: op,
                                         permissions: [Self.view, Self.plain],
                                         grantScopes: [Self.view: [.firms(["82576039", " 47575385"]), .ownDepartment]])
            guard case .ok = output else { Issue.record("expected 200, got \(output)"); return }

            let access = try await timeline.effectiveAccess(employeeAccessId: eaId)
            #expect(access.permissions == [Self.view, Self.plain])
            #expect(access.grantScopes == [Self.view: [.firms(["47575385", "82576039"]), .ownDepartment]])
            let aggregate = try #require(try await repository.find(byId: eaId))
            #expect(aggregate.grantScopes == access.grantScopes)
        }
    }

    @Test func grant_rejects_missing_wrong_or_invalid_scopes() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let op = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: eaId, userId: userId, operatorId: op, repository: repository)
            let sut = handler()

            try expect422(try await grant(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                          permissions: [Self.view]), .grantScopeRequired)
            try expect422(try await grant(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                          permissions: [Self.plain], grantScopes: [Self.plain: [.company]]), .grantScopeNotApplicable)
            try expect422(try await grant(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                          permissions: [Self.group], grantScopes: [Self.group: [.company]]), .grantScopeKindNotAllowed)
            try expect422(try await grant(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                          permissions: [Self.view], grantScopes: [Self.view: [.firms([])]]), .grantScopeInvalid)
            // 全部被擋：沒有任何權限寫進去
            #expect(try await timeline.effectiveAccess(employeeAccessId: eaId).permissions.isEmpty)
        }
    }

    // MARK: - 改範圍

    @Test func change_grant_scope_writes_revoke_and_grant_and_replaces_scopes() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let op = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: eaId, userId: userId, operatorId: op, repository: repository)
            let sut = handler()
            _ = try await grant(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                permissions: [Self.view], grantScopes: [Self.view: [.ownDepartment]])
            let before = try await eventTypes(employeeAccessId: eaId)

            let output = try await change(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                          permission: Self.view, grantScopes: [.firms(["47575385", "82576039"])])
            guard case .ok = output else { Issue.record("expected 200, got \(output)"); return }

            // 不新增事件型別：多兩筆，依序是撤銷、帶新範圍的授予
            let after = try await eventTypes(employeeAccessId: eaId)
            #expect(Array(after.dropFirst(before.count)) == ["PrivilegeRevoked", "PrivilegeGranted"])
            let access = try await timeline.effectiveAccess(employeeAccessId: eaId)
            #expect(access.permissions == [Self.view])
            #expect(access.grantScopes == [Self.view: [.firms(["47575385", "82576039"])]])
        }
    }

    @Test func change_grant_scope_rejects_unchanged_not_held_and_unscoped() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let op = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: eaId, userId: userId, operatorId: op, repository: repository)
            let sut = handler()
            _ = try await grant(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                permissions: [Self.view, Self.plain], grantScopes: [Self.view: [.firms(["82576039", "47575385"])]])

            // 順序、空白不同但正規化後一樣 → 沒變
            try expect422(try await change(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                           permission: Self.view, grantScopes: [.firms(["47575385 ", "82576039"])]), .grantScopeUnchanged)
            try expect422(try await change(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                           permission: Self.group, grantScopes: [.ownDepartment]), .permissionNotExist)
            try expect422(try await change(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                           permission: Self.plain, grantScopes: [.company]), .grantScopeNotApplicable)
            try expect422(try await change(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                           permission: Self.view, grantScopes: []), .grantScopeRequired)
        }
    }

    // 轉換：權限標成範圍化之前就持有（沒有範圍）的人，用改範圍補上。
    @Test func change_grant_scope_supplies_scope_for_grant_made_before_permission_was_scoped() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let op = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: eaId, userId: userId, operatorId: op, repository: repository)
            _ = try await grant(handler(policy: .none), employeeAccessId: eaId, userId: userId, operatorId: op, permissions: [Self.view])
            #expect(try await timeline.effectiveAccess(employeeAccessId: eaId).grantScopes.isEmpty)

            let output = try await change(handler(), employeeAccessId: eaId, userId: userId, operatorId: op,
                                          permission: Self.view, grantScopes: [.ownDepartment])
            guard case .ok = output else { Issue.record("expected 200, got \(output)"); return }
            #expect(try await timeline.effectiveAccess(employeeAccessId: eaId).grantScopes == [Self.view: [.ownDepartment]])
        }
    }

    @Test func revoke_drops_permission_and_scopes() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let op = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: eaId, userId: userId, operatorId: op, repository: repository)
            let sut = handler()
            _ = try await grant(sut, employeeAccessId: eaId, userId: userId, operatorId: op,
                                permissions: [Self.view], grantScopes: [Self.view: [.company]])

            let output = try await sut.revokePrivilege(.init(
                path: .init(employeeAccessId: eaId),
                headers: .init(operatorId: op),
                body: .json(.init(userId: userId, permissions: [Self.view]))
            ))
            guard case .ok = output else { Issue.record("expected 200, got \(output)"); return }
            let access = try await timeline.effectiveAccess(employeeAccessId: eaId)
            #expect(access.permissions.isEmpty)
            #expect(access.grantScopes.isEmpty)
            #expect(try #require(try await repository.find(byId: eaId)).grantScopes.isEmpty)
        }
    }

    // 讀取端寬鬆：事件裡有不認得的範圍種類（日後新增的種類），aggregate 照樣讀得出來，查詢只略過那一項。
    @Test func unknown_kind_in_stored_event_is_skipped_on_read() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let op = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: eaId, userId: userId, operatorId: op, repository: repository)
            let aggregate = try #require(try await repository.find(byId: eaId))
            try aggregate.apply(event: PrivilegeGranted(
                employeeAccessId: eaId, userId: userId, permissions: [Self.view],
                grantScopes: [Self.view: [GrantScope(kind: "teams", firms: nil, departments: nil), .company]],
                occurred: .now
            ))
            try await repository.save(aggregateRoot: aggregate, userId: op)

            let reloaded = try #require(try await repository.find(byId: eaId))
            #expect(reloaded.permissions?.contains(Self.view) == true)
            let access = try await timeline.effectiveAccess(employeeAccessId: eaId)
            #expect(GetPermissionGrantScopesApplicationService.listing(access.grantScopes) == [
                PermissionGrantScopes(permission: Self.view, grantScopes: [.company]),
            ])
        }
    }

    // MARK: - 角色不能帶範圍

    @Test func assign_role_containing_scoped_permission_returns_422() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let op = await bundle.generateId(for: "operatorId")
            let roleId = await bundle.generateId(for: "roleId")
            try await seedActiveProfile(employeeAccessId: eaId, userId: userId, operatorId: op, repository: repository)
            let sut = handler(directory: FakeRoleDirectory(resolved: [roleId: [Self.view, Self.plain]]))

            let output = try await sut.assignRoles(.init(
                path: .init(employeeAccessId: eaId),
                headers: .init(operatorId: op),
                body: .json(.init(userId: userId, roles: [roleId]))
            ))
            guard case .unprocessableContent(let response) = output else { Issue.record("expected 422, got \(output)"); return }
            #expect(try response.body.json.error == .roleContainsScopedPermission)
        }
    }

    @Test func add_scoped_permission_to_role_returns_422() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let op = await bundle.generateId(for: "operatorId")
            let catalogPermission = try #require(PermissionCatalog.allRawValues.sorted().first)
            let roleApi = RoleAggregate.ApiHandler(kdbClient: kdbClient, grantScopePolicy: StaticGrantScopePolicy([catalogPermission: [.company]]))
            let created = try await roleApi.createRole(.init(
                headers: .init(operatorId: op),
                body: .json(.init(name: await bundle.generateId(for: "roleName"), description: "grant scope test"))
            ))
            guard case .ok(let ok) = created else { Issue.record("expected 200, got \(created)"); return }
            let roleId = try ok.body.json.roleId

            let output = try await roleApi.addPermissions(.init(
                path: .init(roleId: roleId),
                headers: .init(operatorId: op),
                body: .json(.init(permissions: [catalogPermission]))
            ))
            guard case .unprocessableContent(let response) = output else { Issue.record("expected 422, got \(output)"); return }
            #expect(try response.body.json.error == .scopedPermissionNotAllowed)
        }
    }

    // MARK: - 查詢（HTTP、gRPC）

    @Test func http_query_unknown_user_returns_404() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let userId = await bundle.generateId(for: "userId")
            let output = try await handler().getPermissionGrantScopes(.init(path: .init(userId: userId)))
            guard case .notFound = output else { Issue.record("expected 404, got \(output)"); return }
        }
    }

    // 需要 IAM_GetPermissions projection（以 userId 讀 link stream）。
    @Test func http_and_grpc_query_list_scoped_permissions() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let op = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: eaId, userId: userId, operatorId: op, repository: repository)
            _ = try await grant(handler(), employeeAccessId: eaId, userId: userId, operatorId: op,
                                permissions: [Self.view, Self.group, Self.plain],
                                grantScopes: [Self.view: [.firms(["47575385"])], Self.group: [.ownDepartment]])
            try await waitForProjection()

            let output = try await handler().getPermissionGrantScopes(.init(path: .init(userId: userId)))
            guard case .ok(let ok) = output else { Issue.record("expected 200, got \(output)"); return }
            let body = try ok.body.json
            #expect(body.map(\.permission) == [Self.group, Self.view])   // 只列範圍化的，依名稱排序
            #expect(body.first { $0.permission == Self.view }?.grantScopes.map { GrantScope(dto: $0) } == [.firms(["47575385"])])

            let sut = PermissionsService(kdbClient: kdbClient, roleDirectory: FakeRoleDirectory())
            let response = try await sut.getPermissionGrantScopes(
                request: .init(metadata: [:], message: .with { $0.userID = userId }),
                context: .init(descriptor: .init(fullyQualifiedService: "IAMContext.PermissionsService", method: "GetPermissionGrantScopes"),
                               remotePeer: "test", localPeer: "test", cancellation: .init())
            )
            switch response.accepted {
            case .success(let contents):
                #expect(contents.message.permissions.map(\.permission) == [Self.group, Self.view])
                let view = contents.message.permissions.first { $0.permission == Self.view }
                #expect(view?.grantScopes.map(\.kind) == ["firms"])
                #expect(view?.grantScopes.first?.firms == ["47575385"])
            case .failure(let error):
                Issue.record("expected success, got gRPC error: \(error)")
            }
        }
    }

    @Test func grpc_query_unknown_user_returns_empty_success() async throws {
        let sut = PermissionsService(kdbClient: kdbClient, roleDirectory: FakeRoleDirectory())
        let response = try await sut.getPermissionGrantScopes(
            request: .init(metadata: [:], message: .with { $0.userID = "grant-scope-unknown-\(UUID().uuidString)" }),
            context: .init(descriptor: .init(fullyQualifiedService: "IAMContext.PermissionsService", method: "GetPermissionGrantScopes"),
                           remotePeer: "test", localPeer: "test", cancellation: .init())
        )
        switch response.accepted {
        case .success(let contents):
            #expect(contents.message.permissions.isEmpty)
        case .failure(let error):
            Issue.record("expected empty success, got gRPC error: \(error)")
        }
    }

    @Test func debug_override_is_returned_for_any_user() async throws {
        let override = GetPermissionGrantScopesApplicationService.debugOverride(scopedPermissions: [Self.view])
        let sut = EmployeeAccessAggregate.ApiHandler(kdbClient: kdbClient, roleDirectory: FakeRoleDirectory(),
                                                     grantScopePolicy: Self.policy, debugOverrideGrantScopes: override)
        let output = try await sut.getPermissionGrantScopes(.init(path: .init(userId: "any-user-debug")))
        guard case .ok(let ok) = output else { Issue.record("expected 200, got \(output)"); return }
        #expect(try ok.body.json.map(\.permission) == [Self.view])
        #expect(try ok.body.json.first?.grantScopes.map(\.kind) == ["company"])

        let grpc = PermissionsService(kdbClient: kdbClient, roleDirectory: FakeRoleDirectory(), debugConfig: DebugConfig(fullPermissions: true))
        let response = try await grpc.getPermissionGrantScopes(
            request: .init(metadata: [:], message: .with { $0.userID = "any-user-debug" }),
            context: .init(descriptor: .init(fullyQualifiedService: "IAMContext.PermissionsService", method: "GetPermissionGrantScopes"),
                           remotePeer: "test", localPeer: "test", cancellation: .init())
        )
        switch response.accepted {
        case .success(let contents):
            #expect(contents.message.permissions.map(\.permission) == PermissionCatalog.grantScopeKinds.keys.sorted())
            #expect(Array(contents.metadata[stringValues: "x-iam-debug"]).contains("1"))
        case .failure(let error):
            Issue.record("expected success, got gRPC error: \(error)")
        }
    }
}
