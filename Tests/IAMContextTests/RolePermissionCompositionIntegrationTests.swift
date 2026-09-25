import Testing
import DDDKit
import Foundation
import KurrentDB
import TestUtility
import GRPCCore
import Generated
import EmployeeAccessAggregate
import IAMContextShared
import IAMPermissionCatalog
import RoleAggregate
@testable import IAMContextServer

// 階段二整合測試（docs/tasks/role-permission-composition.md 驗收標準，9 條）。
//
// 前提：KurrentDB localhost:2113；projection IAM_GetPermissions / IAM_GetRoles / IAM_RoleHolders / IAM_PermissionHolders 已部署。
// - 角色展開（RoleAggregateDirectory.resolve）走 rehydrate → 強一致，角色編輯後**不等待**直接查。
// - 員工事件（assign/grant）進 read model 要經 projection → 等 waitForProjection()。
@Suite(.serialized)
struct RolePermissionCompositionIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let roleRepository: RoleRepository
    let employeeAccessRepository: EmployeeAccessRepository
    /// 生產路徑的 RoleDirectory（階段一 + 階段二串起來測）。
    let directory: RoleAggregateDirectory

    init() {
        self.roleRepository = RoleRepository(
            coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper())
        )
        self.employeeAccessRepository = EmployeeAccessRepository(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
        self.directory = RoleAggregateDirectory(kdbClient: kdbClient)
    }

    // #1 兩入口：createRole → addPermissions → assignRoles → HTTP 與 gRPC 都含該權限。
    @Test func create_role_add_permissions_assign_reflects_in_both_http_and_grpc() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = catalogPermission(at: 10)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [permission])
            let (_, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()

            let http = try await httpPermissions(userId: userId, directory: directory)
            let grpc = try await grpcPermissions(userId: userId, directory: directory)
            #expect(http.contains(permission))
            #expect(grpc.contains(permission))
        }
    }

    // #2 零扇出：兩位持有者，removePermissions 後兩入口立即不含（不等待），且兩位員工的 stream 版本不變。
    @Test func remove_permission_from_role_with_two_holders_reflects_immediately_with_zero_fanout() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = catalogPermission(at: 11)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [permission])
            let (eaId1, userId1) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            let (eaId2, userId2) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()

            #expect(try await httpPermissions(userId: userId1, directory: directory).contains(permission))
            #expect(try await grpcPermissions(userId: userId2, directory: directory).contains(permission))
            let versionsBefore = try await streamVersions(of: [eaId1, eaId2])

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId, permissions: [permission], operatorId: operatorId
            ))

            // 不 sleep、不重啟：角色部分是 rehydrate，下一個查詢即反映。
            #expect(!(try await httpPermissions(userId: userId1, directory: directory).contains(permission)))
            #expect(!(try await grpcPermissions(userId: userId1, directory: directory).contains(permission)))
            #expect(!(try await httpPermissions(userId: userId2, directory: directory).contains(permission)))
            #expect(!(try await grpcPermissions(userId: userId2, directory: directory).contains(permission)))

            // 零扇出：兩位持有者的 EmployeeAccess stream 在角色編輯前後沒有任何新事件。
            let versionsAfter = try await streamVersions(of: [eaId1, eaId2])
            #expect(versionsBefore == versionsAfter)
        }
    }

    // #3 刪除角色：該角色權限消失，直接授權仍在。
    @Test func delete_role_removes_its_permissions_but_direct_grant_remains() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let rolePermission = catalogPermission(at: 12)
            let directPermission = catalogPermission(at: 13)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [rolePermission])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            _ = try await GrantPrivilegeService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, permissions: [directPermission], operatorId: operatorId
            ))
            try await waitForProjection()
            let before = try await httpPermissions(userId: userId, directory: directory)
            #expect(before.contains(rolePermission) && before.contains(directPermission))

            _ = try await DeleteRoleService(repository: roleRepository).execute(input: .init(roleId: roleId, operatorId: operatorId))

            let after = try await httpPermissions(userId: userId, directory: directory)
            #expect(!after.contains(rolePermission))
            #expect(after.contains(directPermission))
        }
    }

    // #4 同一權限同時來自直接授權與角色：從角色移除後仍有效。
    @Test func permission_from_both_direct_grant_and_role_remains_after_role_removes_it() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = catalogPermission(at: 14)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [permission])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            _ = try await GrantPrivilegeService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, permissions: [permission], operatorId: operatorId
            ))
            try await waitForProjection()
            #expect(try await httpPermissions(userId: userId, directory: directory).contains(permission))

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId, permissions: [permission], operatorId: operatorId
            ))

            #expect(try await httpPermissions(userId: userId, directory: directory).contains(permission))
        }
    }

    // #5 同一權限存在於兩個角色：從其一移除後仍有效。
    @Test func permission_shared_by_two_roles_remains_after_removing_from_one() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = catalogPermission(at: 15)
            let roleA = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [permission])
            let roleB = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [permission])
            let (_, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleA, roleB])
            try await waitForProjection()
            #expect(try await httpPermissions(userId: userId, directory: directory).contains(permission))

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleA, permissions: [permission], operatorId: operatorId
            ))
            #expect(try await httpPermissions(userId: userId, directory: directory).contains(permission))

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleB, permissions: [permission], operatorId: operatorId
            ))
            #expect(!(try await httpPermissions(userId: userId, directory: directory).contains(permission)))
        }
    }

    // #6 assignRoles 帶未知 roleId → roleNotFound（生產 directory 與顯式空 fake 各驗一次）。
    @Test func assign_roles_with_unknown_roleId_throws_roleNotFound() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [])
            let unknownRoleId = UUID().uuidString

            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: AssignRolesOutput = try await AssignRolesService(repository: employeeAccessRepository, roleDirectory: directory).execute(input: .init(
                    employeeAccessId: eaId, userId: userId, roles: [unknownRoleId], operatorId: operatorId
                ))
            }
            #expect(error?.error == .roleNotFound)

            let fakeError = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: AssignRolesOutput = try await AssignRolesService(repository: employeeAccessRepository, roleDirectory: FakeRoleDirectory(resolved: [:])).execute(input: .init(
                    employeeAccessId: eaId, userId: userId, roles: ["any-role"], operatorId: operatorId
                ))
            }
            #expect(fakeError?.error == .roleNotFound)

            // 沒有任何事件被寫入：aggregate 的 roles 仍為空。
            let aggregate = try #require(try await employeeAccessRepository.find(byId: eaId))
            #expect((aggregate.roles ?? []).isEmpty)
        }
    }

    // #7 舊字串 roles（非 roleId）：解析不到 → 零權限貢獻、不報錯。
    @Test func legacy_role_string_in_rolesAssigned_contributes_zero_permissions_without_error() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let directPermission = catalogPermission(at: 16)
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [])
            // 用 permissive fake 繞過存在性驗證，寫入一筆帶舊字串的 RolesAssigned（模擬歷史資料）。
            _ = try await AssignRolesService(repository: employeeAccessRepository, roleDirectory: FakeRoleDirectory()).execute(input: .init(
                employeeAccessId: eaId, userId: userId, roles: ["legacy-admin"], operatorId: operatorId
            ))
            _ = try await GrantPrivilegeService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, permissions: [directPermission], operatorId: operatorId
            ))
            try await waitForProjection()

            let http = try await httpPermissions(userId: userId, directory: directory)
            let grpc = try await grpcPermissions(userId: userId, directory: directory)
            #expect(Set(http) == Set([directPermission]))
            #expect(Set(grpc) == Set([directPermission]))
        }
    }

    // #8 注入生效：兩個入口都真的使用注入的假目錄。
    @Test func injected_fake_role_directory_is_used_by_both_http_and_grpc_entrypoints() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let fakeRoleId = await bundle.generateId(for: "fakeRole")
            let fakePermission = await bundle.generateId(for: "fakePermission")
            let fake = FakeRoleDirectory(resolved: [fakeRoleId: [fakePermission]])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [])
            _ = try await AssignRolesService(repository: employeeAccessRepository, roleDirectory: fake).execute(input: .init(
                employeeAccessId: eaId, userId: userId, roles: [fakeRoleId], operatorId: operatorId
            ))
            try await waitForProjection()

            #expect(try await httpPermissions(userId: userId, directory: fake).contains(fakePermission))
            #expect(try await grpcPermissions(userId: userId, directory: fake).contains(fakePermission))
            // 對照：生產 directory 解析不到這個假 roleId → 不含。
            #expect(!(try await httpPermissions(userId: userId, directory: directory).contains(fakePermission)))
        }
    }

    // #9 反查：只經由角色持有權限 p 的人，getPermissionHolders(p) 列出他；帶 department 過濾結果一致；從角色移除 p 後不再列出。
    @Test func get_permission_holders_via_role_only_reflects_role_membership_with_department_filter() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = catalogPermission(at: 17)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [permission])
            let (_, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId], department: "資訊部門")
            try await waitForProjection()   // GetRoles 目錄 + GetRoleHolders projection

            let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient, roleDirectory: directory)
            #expect(try await service.execute(input: .init(permission: permission)).contains(userId))
            #expect(try await service.execute(input: .init(permission: permission, department: "資訊部門")).contains(userId))
            #expect(!(try await service.execute(input: .init(permission: permission, department: "業務部門")).contains(userId)))

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId, permissions: [permission], operatorId: operatorId
            ))
            try await waitForProjection()   // rolesContaining 走 GetRoles projection（最終一致）

            #expect(!(try await service.execute(input: .init(permission: permission)).contains(userId)))
        }
    }

    // MARK: - helpers

    private func createRole(bundle: TestBundle, operatorId: String, permissions: [String]) async throws -> String {
        let output = try await CreateRoleService(repository: roleRepository).execute(input: .init(
            name: await bundle.generateId(for: "roleName"),
            description: "phase-2 composition test",
            operatorId: operatorId
        ))
        if !permissions.isEmpty {
            _ = try await AddPermissionsService(repository: roleRepository).execute(input: .init(
                roleId: output.roleId, permissions: permissions, operatorId: operatorId
            ))
        }
        return output.roleId
    }

    /// 建 active profile；roles 非空時以生產 directory 指派（驗證 roleId 存在）。
    private func seedEmployee(bundle: TestBundle, operatorId: String, roles: [String], department: String = "資訊部門") async throws -> (employeeAccessId: String, userId: String) {
        let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
        let userId = await bundle.generateId(for: "userId")
        try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, department: department, repository: employeeAccessRepository)
        if !roles.isEmpty {
            _ = try await AssignRolesService(repository: employeeAccessRepository, roleDirectory: directory).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, roles: roles, operatorId: operatorId
            ))
        }
        return (employeeAccessId, userId)
    }

    /// HTTP 入口：EmployeeAccessAggregate.ApiHandler.getPermissions。
    private func httpPermissions(userId: String, directory: any RoleDirectory) async throws -> [String] {
        let handler = EmployeeAccessAggregate.ApiHandler(kdbClient: kdbClient, roleDirectory: directory)
        let output = try await handler.getPermissions(.init(path: .init(userId: userId)))
        guard case .ok(let ok) = output, case .json(let permissions) = ok.body else {
            Issue.record("expected 200 json permissions, got \(output)")
            return []
        }
        return permissions
    }

    /// gRPC 入口：PermissionsService.getPermissions（直呼，不起真實 gRPC server；比照 GetPermissionsIntegrationTests）。
    private func grpcPermissions(userId: String, directory: any RoleDirectory) async throws -> [String] {
        let sut = PermissionsService(kdbClient: kdbClient, roleDirectory: directory, debugConfig: DebugConfig(fullPermissions: false))
        let request = ServerRequest<IAMContext_GetPermissionsRequest>(metadata: [:], message: .with { $0.userID = userId })
        let ctx = ServerContext(
            descriptor: .init(fullyQualifiedService: "IAMContext.PermissionsService", method: "GetPermissions"),
            remotePeer: "test", localPeer: "test", cancellation: .init()
        )
        let response = try await sut.getPermissions(request: request, context: ctx)
        switch response.accepted {
        case .success(let contents):
            return contents.message.permissions
        case .failure(let error):
            Issue.record("expected success, got gRPC error: \(error)")
            return []
        }
    }

    /// 各 EmployeeAccess stream 的目前版本（rehydrate 後 metadata.version）。角色編輯前後必須相同＝零扇出。
    private func streamVersions(of employeeAccessIds: [String]) async throws -> [String: UInt64?] {
        var versions: [String: UInt64?] = [:]
        for id in employeeAccessIds {
            let aggregate = try #require(try await employeeAccessRepository.find(byId: id))
            versions[id] = aggregate.metadata.version
        }
        return versions
    }

    private func catalogPermission(at index: Int) -> String {
        let sorted = PermissionCatalog.allRawValues.sorted()
        return sorted[index % sorted.count]
    }

    private func waitForProjection() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }
}
