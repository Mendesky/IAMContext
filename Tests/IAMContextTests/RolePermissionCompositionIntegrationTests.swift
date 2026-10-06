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
    private var timeline: PermissionTimelineService {
        PermissionTimelineService(kdbClient: kdbClient, roleDirectory: directory)
    }

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
            _ = try await GrantPrivilegeService(repository: employeeAccessRepository, effectivePermissionsReader: timeline).execute(input: .init(
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

    // #4 同一權限同時來自直接授權與角色：從角色移除後失效（時間軸後發生者勝）。
    @Test func permission_from_both_direct_grant_and_role_is_lost_when_role_removes_it() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = catalogPermission(at: 14)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [permission])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            _ = try await GrantPrivilegeService(repository: employeeAccessRepository, effectivePermissionsReader: timeline).execute(input: .init(
                employeeAccessId: eaId, userId: userId, permissions: [permission], operatorId: operatorId
            ))
            try await waitForProjection()
            #expect(try await httpPermissions(userId: userId, directory: directory).contains(permission))

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId, permissions: [permission], operatorId: operatorId
            ))

            #expect(!(try await httpPermissions(userId: userId, directory: directory).contains(permission)))
            #expect(!(try await grpcPermissions(userId: userId, directory: directory).contains(permission)))
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
            _ = try await GrantPrivilegeService(repository: employeeAccessRepository, effectivePermissionsReader: timeline).execute(input: .init(
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
            try await waitForProjection()   // 角色候選人走 GetRoles projection（最終一致）

            #expect(!(try await service.execute(input: .init(permission: permission)).contains(userId)))
        }
    }

    // #10 撤銷員工身上的角色（GetPermissionsPresenter 收到 RolesRevoked 後把 roleId 從 read model 移除）：
    // 員工持有 A、B；p 兩個角色都有、q 只有 A。撤銷 A 之後 p 仍在（B 還在供應）、q 消失。HTTP 與 gRPC 兩入口都驗。
    @Test func revoke_one_of_two_roles_keeps_shared_permission_and_drops_the_exclusive_one() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let sharedPermission = catalogPermission(at: 18)      // p：A、B 都有
            let exclusivePermission = catalogPermission(at: 19)   // q：只有 A 有
            let roleA = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [sharedPermission, exclusivePermission])
            let roleB = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [sharedPermission])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleA, roleB])
            try await waitForProjection()

            // 前置：撤銷前兩入口都含 p、q（否則後面的「q 消失」證明不了任何事）。
            let httpBefore = try await httpPermissions(userId: userId, directory: directory)
            let grpcBefore = try await grpcPermissions(userId: userId, directory: directory)
            #expect(httpBefore.contains(sharedPermission) && httpBefore.contains(exclusivePermission))
            #expect(grpcBefore.contains(sharedPermission) && grpcBefore.contains(exclusivePermission))

            _ = try await RevokeRolesService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, roles: [roleA], operatorId: operatorId
            ))
            try await waitForProjection()   // RolesRevoked 要經 projection 才進 read model

            let http = try await httpPermissions(userId: userId, directory: directory)
            let grpc = try await grpcPermissions(userId: userId, directory: directory)
            #expect(http.contains(sharedPermission))
            #expect(grpc.contains(sharedPermission))
            #expect(!http.contains(exclusivePermission))
            #expect(!grpc.contains(exclusivePermission))
        }
    }

    // #11 員工只持有角色 A（含 q）、沒有任何直接授權：撤銷 A 之後兩入口的有效權限為空（q 消失，且不會冒出別的東西）。
    @Test func revoke_sole_role_removes_its_permissions_and_leaves_none_without_direct_grants() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = catalogPermission(at: 20)
            let roleA = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [permission])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleA])
            try await waitForProjection()
            #expect(try await httpPermissions(userId: userId, directory: directory).contains(permission))
            #expect(try await grpcPermissions(userId: userId, directory: directory).contains(permission))

            _ = try await RevokeRolesService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, roles: [roleA], operatorId: operatorId
            ))
            try await waitForProjection()

            #expect(try await httpPermissions(userId: userId, directory: directory).isEmpty)
            #expect(try await grpcPermissions(userId: userId, directory: directory).isEmpty)
        }
    }

    // #12 撤銷角色不動直接授權：員工持有角色 A（含 q）＋直接授權 d。撤銷 A 之後 q 消失、d 原封不動。
    @Test func revoke_role_leaves_directly_granted_permissions_untouched() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let rolePermission = catalogPermission(at: 21)
            let directPermission = catalogPermission(at: 22)
            let roleA = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [rolePermission])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleA])
            _ = try await GrantPrivilegeService(repository: employeeAccessRepository, effectivePermissionsReader: timeline).execute(input: .init(
                employeeAccessId: eaId, userId: userId, permissions: [directPermission], operatorId: operatorId
            ))
            try await waitForProjection()
            #expect(Set(try await httpPermissions(userId: userId, directory: directory)) == Set([rolePermission, directPermission]))
            #expect(Set(try await grpcPermissions(userId: userId, directory: directory)) == Set([rolePermission, directPermission]))

            _ = try await RevokeRolesService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, roles: [roleA], operatorId: operatorId
            ))
            try await waitForProjection()

            #expect(Set(try await httpPermissions(userId: userId, directory: directory)) == Set([directPermission]))
            #expect(Set(try await grpcPermissions(userId: userId, directory: directory)) == Set([directPermission]))
        }
    }

    // #13 只來自角色的權限可經 ApiHandler 對個人撤銷，兩入口都消失。
    @Test func revoke_privilege_on_role_only_permission_succeeds_and_disappears_from_http_and_grpc() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 23)
            let q = catalogPermission(at: 24)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p, q])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()

            let first = try await revokePrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId)
            guard case .ok = first else {
                Issue.record("expected 200 on first revoke, got \(first)")
                return
            }
            try await waitForProjection()

            #expect(!((try await httpPermissions(userId: userId, directory: directory)).contains(p)))
            #expect(!((try await grpcPermissions(userId: userId, directory: directory)).contains(p)))
            #expect((try await httpPermissions(userId: userId, directory: directory)).contains(q))
            #expect((try await grpcPermissions(userId: userId, directory: directory)).contains(q))
            #expect((try #require(try await employeeAccessRepository.find(byId: eaId)).permissions ?? []).isEmpty)

            let second = try await revokePrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId)
            guard case .unprocessableContent(let response) = second else {
                Issue.record("expected 422 on second revoke, got \(second)")
                return
            }
            #expect(try response.body.json.error == .permissionNotExist)
            #expect((try #require(try await employeeAccessRepository.find(byId: eaId)).permissions ?? []).isEmpty)
        }
    }

    // #14 直接授權撤銷後，角色後續加入同一權限會把它給回來。
    @Test func direct_grant_revoked_then_role_adds_same_permission_grants_it_back() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 25)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            _ = try await grantPrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            try await waitForProjection()
            #expect((try await httpPermissions(userId: userId, directory: directory)).contains(p))

            _ = try await revokePrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            try await waitForProjection()
            #expect(!((try await httpPermissions(userId: userId, directory: directory)).contains(p)))
            #expect(!((try await grpcPermissions(userId: userId, directory: directory)).contains(p)))

            _ = try await AddPermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId, permissions: [p], operatorId: operatorId
            ))
            #expect((try await httpPermissions(userId: userId, directory: directory)).contains(p))
            #expect((try await grpcPermissions(userId: userId, directory: directory)).contains(p))
        }
    }

    // #15 兩個角色共享同一權限時，刪掉其中一個仍保留；兩個都刪掉才消失。
    @Test func overlapping_roles_delete_role_keeps_shared_permission() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 26)
            let roleA = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let roleB = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let (_, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleA, roleB])
            try await waitForProjection()

            _ = try await DeleteRoleService(repository: roleRepository).execute(input: .init(roleId: roleA, operatorId: operatorId))
            #expect((try await httpPermissions(userId: userId, directory: directory)).contains(p))
            #expect((try await grpcPermissions(userId: userId, directory: directory)).contains(p))

            _ = try await DeleteRoleService(repository: roleRepository).execute(input: .init(roleId: roleB, operatorId: operatorId))
            #expect(!((try await httpPermissions(userId: userId, directory: directory)).contains(p)))
            #expect(!((try await grpcPermissions(userId: userId, directory: directory)).contains(p)))
        }
    }

    // #16 對個人撤銷後，撤銷再重新指派角色會恢復角色權限。
    @Test func individual_revoke_is_undone_by_reassigning_the_role() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 27)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()

            _ = try await revokePrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            try await waitForProjection()
            #expect(!((try await httpPermissions(userId: userId, directory: directory)).contains(p)))

            _ = try await RevokeRolesService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, roles: [roleId], operatorId: operatorId
            ))
            try await waitForProjection()
            _ = try await AssignRolesService(repository: employeeAccessRepository, roleDirectory: directory).execute(input: .init(
                employeeAccessId: eaId, userId: userId, roles: [roleId], operatorId: operatorId
            ))
            try await waitForProjection()
            #expect((try await httpPermissions(userId: userId, directory: directory)).contains(p))
            #expect((try await grpcPermissions(userId: userId, directory: directory)).contains(p))
        }
    }

    // #17 對個人撤銷後，角色移除再重新加入該權限會恢復。
    @Test func individual_revoke_is_undone_when_role_adds_the_permission_again() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 28)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()

            _ = try await revokePrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            try await waitForProjection()
            #expect(!((try await httpPermissions(userId: userId, directory: directory)).contains(p)))

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId, permissions: [p], operatorId: operatorId
            ))
            #expect(!((try await grpcPermissions(userId: userId, directory: directory)).contains(p)))

            _ = try await AddPermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId, permissions: [p], operatorId: operatorId
            ))
            #expect((try await httpPermissions(userId: userId, directory: directory)).contains(p))
            #expect((try await grpcPermissions(userId: userId, directory: directory)).contains(p))
        }
    }

    // #18 對個人撤銷只來自角色的權限後，直接授予可恢復。
    @Test func individual_revoke_is_undone_by_direct_grant() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 29)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()

            _ = try await revokePrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            try await waitForProjection()
            #expect(!((try await httpPermissions(userId: userId, directory: directory)).contains(p)))
            _ = try await grantPrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            try await waitForProjection()
            #expect((try await httpPermissions(userId: userId, directory: directory)).contains(p))
            #expect((try await grpcPermissions(userId: userId, directory: directory)).contains(p))
        }
    }

    // #19 反查結果與時間軸重播一致，且 department filter 一致。
    @Test func get_permission_holders_matches_timeline_replay_including_department_filter() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 30)
            let q = catalogPermission(at: 31)
            let roleWithP = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let roleForU4 = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])

            let (ea1, u1) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [], department: "資訊部門")
            let (_, u2) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleWithP], department: "資訊部門")
            let (ea3, u3) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleWithP], department: "資訊部門")
            let (ea4, u4) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleForU4], department: "資訊部門")
            let (_, u5) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleWithP], department: "業務部門")
            _ = try await grantPrivilege(employeeAccessId: ea1, userId: u1, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            _ = try await revokePrivilege(employeeAccessId: ea3, userId: u3, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            _ = try await grantPrivilege(employeeAccessId: ea4, userId: u4, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            _ = try await grantPrivilege(employeeAccessId: ea4, userId: u4, permissions: [q], operatorId: operatorId, viaApiHandler: false)
            try await waitForProjection()

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleForU4, permissions: [p], operatorId: operatorId
            ))

            let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient, roleDirectory: directory)
            let all = Set(try await service.execute(input: .init(permission: p)))
            let filtered = Set(try await service.execute(input: .init(permission: p, department: "資訊部門")))
            // p 是真實 catalog 權限，本機資料庫裡還有其他員工（匯入資料、其他測試）持有它，
            // 所以只比對本測試建立的 5 位員工。
            let ours: Set<String> = [u1, u2, u3, u4, u5]
            #expect(all.intersection(ours) == Set([u1, u2, u5]))
            #expect(filtered.intersection(ours) == Set([u1, u2]))

            for userId in [u1, u2, u3, u4, u5] {
                let hasPermission = try await httpPermissions(userId: userId, directory: directory).contains(p)
                #expect(all.contains(userId) == hasPermission)
            }
        }
    }

    // #20 角色編輯與刪除不寫任何員工事件，且查詢立即反映。
    @Test func role_edits_and_delete_write_no_employee_events_zero_fanout() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 32)
            let q = catalogPermission(at: 33)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let (ea1, u1) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            let (ea2, u2) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()
            let before = try await streamVersions(of: [ea1, ea2])

            _ = try await AddPermissionsService(repository: roleRepository).execute(input: .init(roleId: roleId, permissions: [q], operatorId: operatorId))
            #expect(Set(try await httpPermissions(userId: u1, directory: directory)) == Set([p, q]))
            #expect(Set(try await grpcPermissions(userId: u2, directory: directory)) == Set([p, q]))

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(roleId: roleId, permissions: [p], operatorId: operatorId))
            #expect(Set(try await httpPermissions(userId: u1, directory: directory)) == Set([q]))
            #expect(Set(try await grpcPermissions(userId: u2, directory: directory)) == Set([q]))

            _ = try await DeleteRoleService(repository: roleRepository).execute(input: .init(roleId: roleId, operatorId: operatorId))
            #expect((try await httpPermissions(userId: u1, directory: directory)).isEmpty)
            #expect((try await grpcPermissions(userId: u2, directory: directory)).isEmpty)
            #expect(before == (try await streamVersions(of: [ea1, ea2])))
        }
    }

    // #21 已刪除角色的歷史仍被重播，且 directory history 保留 created → added → deleted。
    @Test func deleted_role_history_is_replayed_and_directory_history_ends_with_roleDeleted() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 34)
            let q = catalogPermission(at: 35)
            let roleR = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p, q])
            let roleS = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [q])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleR, roleS])
            try await waitForProjection()

            _ = try await DeleteRoleService(repository: roleRepository).execute(input: .init(roleId: roleR, operatorId: operatorId))
            let afterDelete = Set(try await httpPermissions(userId: userId, directory: directory))
            #expect(afterDelete == Set([q]))
            #expect(Set(try await grpcPermissions(userId: userId, directory: directory)) == Set([q]))

            _ = try await RevokeRolesService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, roles: [roleR], operatorId: operatorId
            ))
            try await waitForProjection()
            #expect(Set(try await httpPermissions(userId: userId, directory: directory)) == Set([q]))

            let history = try await directory.history(ofRoles: [roleR])
            #expect(history.count == 3)
            #expect(history.map(\.event) == [
                .roleCreated(roleId: roleR),
                .rolePermissionsAdded(roleId: roleR, permissions: Set([p, q])),
                .roleDeleted(roleId: roleR),
            ])
            for pair in zip(history, history.dropFirst()) {
                #expect(pair.0.position < pair.1.position)
            }
        }
    }

    // #22 撤銷既非直接授權也非有效權限的權限仍是 permissionNotExist，且不寫事件。
    @Test func revoke_privilege_of_permission_that_is_neither_direct_nor_effective_still_throws_permissionNotExist() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let q = catalogPermission(at: 36)
            let other = catalogPermission(at: 37)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [q])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()
            let before = try await streamVersions(of: [eaId])

            for permission in ["custom:new", other] {
                let output = try await revokePrivilege(employeeAccessId: eaId, userId: userId, permissions: [permission], operatorId: operatorId)
                guard case .unprocessableContent(let response) = output else {
                    Issue.record("expected 422 permissionNotExist for \(permission), got \(output)")
                    continue
                }
                #expect(try response.body.json.error == .permissionNotExist)
            }
            #expect(before == (try await streamVersions(of: [eaId])))
        }
    }

    // #23 建檔事件內的初始權限與角色會被時間軸重播。
    @Test func initial_permissions_and_roles_in_profile_created_event_are_replayed() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let direct = catalogPermission(at: 38)
            let viaRole = catalogPermission(at: 39)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [viaRole])
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let aggregate = try EmployeeAccess(
                id: employeeAccessId,
                userId: userId,
                department: "資訊部門",
                jobTitle: "Engineer",
                permissions: [direct],
                roles: [roleId],
                status: .Active,
                firm: "台北所"
            )
            try await employeeAccessRepository.save(aggregateRoot: aggregate, userId: operatorId)
            try await waitForProjection()

            #expect(Set(try await httpPermissions(userId: userId, directory: directory)) == Set([direct, viaRole]))
            #expect(Set(try await grpcPermissions(userId: userId, directory: directory)) == Set([direct, viaRole]))
        }
    }

    // #24 link stream resolve 後的 record.position 必須等於原始 stream 的 record.position。
    @Test func resolved_link_record_position_equals_original_stream_position() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [])
            try await waitForProjection()

            let linked = try await firstReadEvent(streamName: "IAM_GetPermissions-\(userId)", resolveLinks: true)
            let original = try await readEvent(streamName: "IAMEmployeeAccess-\(eaId)", eventId: linked.record.id, resolveLinks: false)
            let link = try #require(linked.link)
            #expect(linked.record.position == original.record.position)
            #expect(position(link.position, isGreaterThan: linked.record.position))
        }
    }

    // #25 角色移除重疊權限後，可經 ApiHandler grantPrivilege 重新給回；再 grant 才回 alreadyExists。
    @Test func grant_privilege_after_role_removes_shared_permission_succeeds_and_returns_it_to_both_entrypoints() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 40)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            _ = try await grantPrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            try await waitForProjection()
            #expect((try await httpPermissions(userId: userId, directory: directory)).contains(p))

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(roleId: roleId, permissions: [p], operatorId: operatorId))
            #expect(!((try await httpPermissions(userId: userId, directory: directory)).contains(p)))
            #expect(!((try await grpcPermissions(userId: userId, directory: directory)).contains(p)))
            #expect((try #require(try await employeeAccessRepository.find(byId: eaId)).permissions ?? []).contains(p))

            let first = try await grantPrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId)
            guard case .ok = first else {
                Issue.record("expected 200 on re-grant, got \(first)")
                return
            }
            try await waitForProjection()
            #expect((try await httpPermissions(userId: userId, directory: directory)).contains(p))
            #expect((try await grpcPermissions(userId: userId, directory: directory)).contains(p))

            let second = try await grantPrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId)
            guard case .unprocessableContent(let response) = second else {
                Issue.record("expected 422 on second grant, got \(second)")
                return
            }
            #expect(try response.body.json.error == .permissionAlreadyExists)
        }
    }

    // #26 改名、改描述、升遷、轉調都不影響有效權限。
    @Test func non_permission_events_do_not_change_effective_permissions() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 41)
            let q = catalogPermission(at: 42)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p, q])
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()

            _ = try await revokePrivilege(employeeAccessId: eaId, userId: userId, permissions: [p], operatorId: operatorId, viaApiHandler: false)
            try await waitForProjection()
            #expect(Set(try await httpPermissions(userId: userId, directory: directory)) == Set([q]))

            _ = try await RenameRoleService(repository: roleRepository).execute(input: .init(
                roleId: roleId, newName: await bundle.generateId(for: "renamedRole"), operatorId: operatorId
            ))
            _ = try await UpdateRoleDescriptionService(repository: roleRepository).execute(input: .init(
                roleId: roleId, newDescription: "updated description", operatorId: operatorId
            ))
            _ = try await PromoteUserService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, newJobTitle: "Senior Engineer", oldJobTitle: "Engineer", operatorId: operatorId
            ))
            _ = try await TransferDepartmentService(repository: employeeAccessRepository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, newDepartment: "產品部門", newJobTitle: "Senior Engineer", operatorId: operatorId, newFirm: "台北所"
            ))
            try await waitForProjection()

            #expect(Set(try await httpPermissions(userId: userId, directory: directory)) == Set([q]))
            #expect(Set(try await grpcPermissions(userId: userId, directory: directory)) == Set([q]))
        }
    }

    // #27 未登記事件型別在角色或員工 stream 內都 fail-closed。
    @Test func unmapped_event_in_role_or_employee_stream_fails_closed() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 43)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let (_, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()

            try await appendBogusEvent(streamName: "IAMRole-\(roleId)")
            let roleError = await #expect(throws: PermissionTimelineError.self) {
                _ = try await directory.history(ofRoles: [roleId])
            }
            guard case .unmappedEvent(_, "BogusEvent")? = roleError else {
                Issue.record("expected unmappedEvent(BogusEvent) from role history, got \(String(describing: roleError))")
                return
            }

            let handler = EmployeeAccessAggregate.ApiHandler(kdbClient: kdbClient, roleDirectory: directory)
            let http = try await handler.getPermissions(.init(path: .init(userId: userId)))
            guard case .serviceUnavailable(let response) = http else {
                Issue.record("expected 503 after bogus role event, got \(http)")
                return
            }
            #expect(try response.body.json.error == .serviceUnavailable)

            let grpc = try await rawGrpcPermissions(userId: userId, directory: directory)
            guard case .failure(let error) = grpc.accepted else {
                Issue.record("expected gRPC failure after bogus role event, got \(grpc)")
                return
            }
            #expect(error.code == .aborted)

            let role2 = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let (eaId2, userId2) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [role2])
            try await waitForProjection()
            let streamName = "IAMEmployeeAccess-\(eaId2)"
            let countBefore = try await rawEventCount(streamName: streamName)
            try await appendBogusEvent(streamName: streamName)
            let employeeError = await #expect(throws: PermissionTimelineError.self) {
                _ = try await timeline.effectivePermissions(employeeAccessId: eaId2)
            }
            guard case .unmappedEvent(_, "BogusEvent")? = employeeError else {
                Issue.record("expected unmappedEvent(BogusEvent) from employee stream, got \(String(describing: employeeError))")
                return
            }

            let revoke = try await revokePrivilege(employeeAccessId: eaId2, userId: userId2, permissions: [p], operatorId: operatorId)
            guard case .serviceUnavailable(let revokeResponse) = revoke else {
                Issue.record("expected revokePrivilege 503 after bogus employee event, got \(revoke)")
                return
            }
            #expect(try revokeResponse.body.json.error == .serviceUnavailable)
            #expect(try await rawEventCount(streamName: streamName) == countBefore + 1)
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

    private func revokePrivilege(
        employeeAccessId: String,
        userId: String,
        permissions: [String],
        operatorId: String,
        viaApiHandler: Bool = true
    ) async throws -> EmployeeAccessAggregate.Operations.revokePrivilege.Output {
        if viaApiHandler {
            let handler = EmployeeAccessAggregate.ApiHandler(kdbClient: kdbClient, roleDirectory: directory)
            return try await handler.revokePrivilege(.init(
                path: .init(employeeAccessId: employeeAccessId),
                headers: .init(operatorId: operatorId),
                body: .json(.init(userId: userId, permissions: permissions))
            ))
        }

        do {
            let output = try await RevokePrivilegeService(repository: employeeAccessRepository, effectivePermissionsReader: timeline).execute(input: .init(
                employeeAccessId: employeeAccessId,
                userId: userId,
                permissions: permissions,
                operatorId: operatorId
            ))
            return .ok(.init(body: .json(.init(employeeAccessId: output.id ?? employeeAccessId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch let error as ContextError<EmployeeAccessError> {
            return .unprocessableContent(.init(body: .json(.init(error: .init(from: error)))))
        } catch {
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    private func grantPrivilege(
        employeeAccessId: String,
        userId: String,
        permissions: [String],
        operatorId: String,
        viaApiHandler: Bool = true
    ) async throws -> EmployeeAccessAggregate.Operations.grantPrivilege.Output {
        if viaApiHandler {
            let handler = EmployeeAccessAggregate.ApiHandler(kdbClient: kdbClient, roleDirectory: directory)
            return try await handler.grantPrivilege(.init(
                path: .init(employeeAccessId: employeeAccessId),
                headers: .init(operatorId: operatorId),
                body: .json(.init(userId: userId, permissions: permissions))
            ))
        }

        do {
            let output = try await GrantPrivilegeService(repository: employeeAccessRepository, effectivePermissionsReader: timeline).execute(input: .init(
                employeeAccessId: employeeAccessId,
                userId: userId,
                permissions: permissions,
                operatorId: operatorId
            ))
            return .ok(.init(body: .json(.init(employeeAccessId: output.id ?? employeeAccessId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch let error as ContextError<EmployeeAccessError> {
            return .unprocessableContent(.init(body: .json(.init(error: .init(from: error)))))
        } catch {
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
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

    private func rawGrpcPermissions(userId: String, directory: any RoleDirectory) async throws -> ServerResponse<IAMContext_GetPermissionsResponse> {
        let sut = PermissionsService(kdbClient: kdbClient, roleDirectory: directory, debugConfig: DebugConfig(fullPermissions: false))
        let request = ServerRequest<IAMContext_GetPermissionsRequest>(metadata: [:], message: .with { $0.userID = userId })
        let ctx = ServerContext(
            descriptor: .init(fullyQualifiedService: "IAMContext.PermissionsService", method: "GetPermissions"),
            remotePeer: "test", localPeer: "test", cancellation: .init()
        )
        return try await sut.getPermissions(request: request, context: ctx)
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

    private func firstReadEvent(streamName: String, resolveLinks: Bool) async throws -> ReadEvent {
        let responses = try await kdbClient.streams(specified: streamName).read {
            $0.resolveLinks = resolveLinks
        }
        for try await response in responses {
            if case let .event(readEvent) = response {
                return readEvent
            }
        }
        throw MissingReadEvent(streamName: streamName)
    }

    private func readEvent(streamName: String, eventId: UUID, resolveLinks: Bool) async throws -> ReadEvent {
        let responses = try await kdbClient.streams(specified: streamName).read {
            $0.resolveLinks = resolveLinks
        }
        for try await response in responses {
            if case let .event(readEvent) = response, readEvent.record.id == eventId {
                return readEvent
            }
        }
        throw MissingReadEvent(streamName: streamName)
    }

    private func rawEventCount(streamName: String) async throws -> Int {
        var count = 0
        let responses = try await kdbClient.streams(specified: streamName).read()
        for try await response in responses {
            if case .event = response {
                count += 1
            }
        }
        return count
    }

    private func appendBogusEvent(streamName: String) async throws {
        try await kdbClient.streams(specified: streamName).append(events: [
            EventData(eventType: "BogusEvent", model: BogusPayload(message: "fail closed"))
        ])
    }

    private func position(_ lhs: StreamPosition, isGreaterThan rhs: StreamPosition) -> Bool {
        (lhs.commit, lhs.prepare) > (rhs.commit, rhs.prepare)
    }

    private func catalogPermission(at index: Int) -> String {
        let sorted = PermissionCatalog.allRawValues.sorted()
        return sorted[index % sorted.count]
    }

    private func waitForProjection() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    private struct BogusPayload: Codable, Sendable {
        let message: String
    }

    private struct MissingReadEvent: Error {
        let streamName: String
    }
}
