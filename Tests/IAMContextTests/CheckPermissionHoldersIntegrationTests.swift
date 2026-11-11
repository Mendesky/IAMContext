import Testing
import DDDKit
import Foundation
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared
import IAMPermissionCatalog
import RoleAggregate

// 持有者判斷（permission-holder-check）整合測試：CheckPermissionHoldersApplicationService 與其 HTTP 入口。
//
// 語意＝getPermissionHolders 限縮在給定的 userIds：同一套時間軸重播規則（被個別撤銷、角色移除該權限 → 不算持有），
// 且不受 IAM_DEBUG_FULL_PERMISSIONS 影響。
//
// 前提：KDB `IAM_GetPermissions` projection 已部署（員工側 link stream `IAM_GetPermissions-<userId>`）；
// 與 getPermissionHolders 對照的那條另需 `IAM_PermissionHolders`／`IAM_RoleHolders`／`IAM_GetRoles`。
// - 員工事件（grant/revoke/assign）進 link stream 經 projection（非同步）→ 以 waitForProjection() 等待
//   （同 GetPermissionHoldersIntegrationTests 慣例）。
// - 角色歷史走 RoleAggregateDirectory 直接讀角色 stream（強一致）→ 角色編輯後不必等。
@Suite(.serialized)
struct CheckPermissionHoldersIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let repository: EmployeeAccessRepository
    let roleRepository: RoleRepository
    /// 生產路徑的 RoleDirectory：經角色持有的情境要真的重播角色歷史。
    let directory: RoleAggregateDirectory
    private var timeline: PermissionTimelineService {
        PermissionTimelineService(kdbClient: kdbClient, roleDirectory: directory)
    }
    private var service: CheckPermissionHoldersApplicationService {
        CheckPermissionHoldersApplicationService(kdbClient: kdbClient, roleDirectory: directory)
    }

    init() {
        self.repository = EmployeeAccessRepository(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
        self.roleRepository = RoleRepository(
            coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper())
        )
        self.directory = RoleAggregateDirectory(kdbClient: kdbClient)
    }

    // MARK: - 判斷規則（與 getPermissionHolders 同一套重播）

    // 直接授予 → 是持有者
    @Test func direct_grant_is_holder() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = await bundle.generateId(for: "perm")
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            try await grant(employeeAccessId: eaId, userId: userId, permissions: [permission], operatorId: operatorId)
            try await waitForProjection()

            let output = try await service.execute(input: .init(permission: permission, userIds: [userId]))
            #expect(output.holders == [userId], "直接授予者應為持有者")
        }
    }

    // 授予後被個別撤銷 → 不是持有者
    @Test func granted_then_revoked_is_not_holder() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = await bundle.generateId(for: "perm")
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            try await grant(employeeAccessId: eaId, userId: userId, permissions: [permission], operatorId: operatorId)
            try await waitForProjection()

            let beforeRevoke = try await service.execute(input: .init(permission: permission, userIds: [userId]))
            #expect(beforeRevoke.holders == [userId], "撤銷前應為持有者")

            try await revoke(employeeAccessId: eaId, userId: userId, permissions: [permission], operatorId: operatorId)
            try await waitForProjection()

            let afterRevoke = try await service.execute(input: .init(permission: permission, userIds: [userId]))
            #expect(afterRevoke.holders.isEmpty, "個別撤銷後不應為持有者")
        }
    }

    // 只經角色持有 → 是持有者
    @Test func granted_via_role_is_holder() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = catalogPermission(at: 40)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [permission])
            let (_, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()

            let output = try await service.execute(input: .init(permission: permission, userIds: [userId]))
            #expect(output.holders == [userId], "經角色持有者應為持有者")
        }
    }

    // 角色之後被移除該權限 → 不是持有者（角色歷史強一致，不必等 projection）
    @Test func role_later_lost_permission_is_not_holder() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = catalogPermission(at: 41)
            let roleId = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [permission])
            let (_, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleId])
            try await waitForProjection()

            let beforeRemove = try await service.execute(input: .init(permission: permission, userIds: [userId]))
            #expect(beforeRemove.holders == [userId], "角色移除權限前應為持有者")

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleId, permissions: [permission], operatorId: operatorId
            ))

            let afterRemove = try await service.execute(input: .init(permission: permission, userIds: [userId]))
            #expect(afterRemove.holders.isEmpty, "角色移除該權限後不應為持有者")
        }
    }

    // 與 getPermissionHolders 對照：同一批人、同一套規則，結果必須相同。
    // U1 只被直接授予、U2 只經角色、U3 經角色但被個別撤銷、U4 直接授予且角色也有但角色後來移除（D4）、U5 只經角色。
    @Test func matches_get_permission_holders_restricted_to_requested_users() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let p = catalogPermission(at: 42)
            let roleWithP = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])
            let roleForU4 = try await createRole(bundle: bundle, operatorId: operatorId, permissions: [p])

            let (ea1, u1) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            let (_, u2) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleWithP])
            let (ea3, u3) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleWithP])
            let (ea4, u4) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleForU4])
            let (_, u5) = try await seedEmployee(bundle: bundle, operatorId: operatorId, roles: [roleWithP])
            try await grant(employeeAccessId: ea1, userId: u1, permissions: [p], operatorId: operatorId)
            try await revoke(employeeAccessId: ea3, userId: u3, permissions: [p], operatorId: operatorId)
            try await grant(employeeAccessId: ea4, userId: u4, permissions: [p], operatorId: operatorId)
            try await waitForProjection()

            _ = try await RemovePermissionsService(repository: roleRepository).execute(input: .init(
                roleId: roleForU4, permissions: [p], operatorId: operatorId
            ))

            let ours = [u1, u2, u3, u4, u5]
            let checked = Set(try await service.execute(input: .init(permission: p, userIds: ours)).holders)
            // p 是真實 catalog 權限，資料庫裡可能還有其他員工持有它，所以只比對本測試建立的 5 位。
            let allHolders = Set(try await GetPermissionHoldersApplicationService(kdbClient: kdbClient, roleDirectory: directory)
                .execute(input: .init(permission: p)))

            #expect(checked == Set([u1, u2, u5]))
            #expect(checked == allHolders.intersection(ours), "持有者判斷必須等於 getPermissionHolders 限縮在這批人")
        }
    }

    // MARK: - 輸入邊界

    // 不存在於 IAM 的 userId → 靜默排除，不拋錯
    @Test func unknown_userId_is_silently_excluded() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = await bundle.generateId(for: "perm")
            let unknownUserId = await bundle.generateId(for: "unknownUserId")
            let (eaId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            try await grant(employeeAccessId: eaId, userId: userId, permissions: [permission], operatorId: operatorId)
            try await waitForProjection()

            let output = try await service.execute(input: .init(permission: permission, userIds: [unknownUserId, userId]))
            #expect(output.holders == [userId], "查無此人的 userId 應被靜默排除，而非拋錯")
        }
    }

    // userIds 為空 → 回空陣列（不查 KDB）
    @Test func empty_userIds_returns_empty_holders() async throws {
        let output = try await service.execute(input: .init(permission: "Any.Permission", userIds: []))
        #expect(output.holders.isEmpty, "空輸入應回空陣列，不拋錯")
    }

    // 重複的 userId → 只出現一次
    @Test func duplicate_userIds_are_deduped() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = await bundle.generateId(for: "perm")
            let (ea1, u1) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            let (ea2, u2) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            try await grant(employeeAccessId: ea1, userId: u1, permissions: [permission], operatorId: operatorId)
            try await grant(employeeAccessId: ea2, userId: u2, permissions: [permission], operatorId: operatorId)
            try await waitForProjection()

            let output = try await service.execute(input: .init(permission: permission, userIds: [u1, u1, u2, u1, u2]))
            #expect(output.holders.count == 2, "重複的 userId 只能出現一次")
            #expect(Set(output.holders) == Set([u1, u2]))
        }
    }

    // 只回請求裡的人：名單外的人即使持有該權限也不出現
    @Test func only_requested_users_are_returned_even_if_others_hold_it() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = await bundle.generateId(for: "perm")
            let (ea1, u1) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            let (ea2, u2) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            let (ea3, u3) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            for (eaId, userId) in [(ea1, u1), (ea2, u2), (ea3, u3)] {
                try await grant(employeeAccessId: eaId, userId: userId, permissions: [permission], operatorId: operatorId)
            }
            try await waitForProjection()

            // 前提確認：u3 確實是持有者（全體反查查得到）
            let allHolders = try await GetPermissionHoldersApplicationService(kdbClient: kdbClient, roleDirectory: directory)
                .execute(input: .init(permission: permission))
            #expect(allHolders.contains(u3))

            let output = try await service.execute(input: .init(permission: permission, userIds: [u1, u2]))
            #expect(Set(output.holders) == Set([u1, u2]), "名單外的持有者（u3）不應出現")
        }
    }

    // MARK: - HTTP 入口（ApiHandler.checkPermissionHolders）

    // IAM_DEBUG_FULL_PERMISSIONS 開啟時，getPermissions 對任何人回全部 catalog；持有者判斷不受影響。
    @Test func handler_ignores_debug_full_permissions() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let permission = catalogPermission(at: 43)
            let (eaHolder, holder) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            let (_, nonHolder) = try await seedEmployee(bundle: bundle, operatorId: operatorId)
            try await grant(employeeAccessId: eaHolder, userId: holder, permissions: [permission], operatorId: operatorId)
            try await waitForProjection()

            let handler = EmployeeAccessAggregate.ApiHandler(
                kdbClient: kdbClient,
                roleDirectory: directory,
                debugOverridePermissions: Array(PermissionCatalog.allRawValues).sorted()
            )

            // 前提確認：debug 確實開著——沒被授予的人 getPermissions 也拿得到該權限。
            let debugPermissions = try await handler.getPermissions(.init(path: .init(userId: nonHolder)))
            guard case .ok(let ok) = debugPermissions else {
                Issue.record("expected 200 from getPermissions, got \(debugPermissions)")
                return
            }
            #expect(try ok.body.json.contains(permission))

            let output = try await handler.checkPermissionHolders(.init(
                headers: .init(operatorId: operatorId),
                body: .json(.init(permission: permission, userIds: [holder, nonHolder]))
            ))
            guard case .ok(let response) = output else {
                Issue.record("expected 200, got \(output)")
                return
            }
            #expect(try response.body.json.holders == [holder], "debug 模式不應讓未持有者被判為持有者")
        }
    }

    // permission 為空字串／空白（含全形空白）→ 422 invalidPayload（不查 KDB）
    @Test(arguments: ["", "   ", "\u{3000}", "\n"])
    func handler_rejects_blank_permission_with_422(permission: String) async throws {
        let handler = EmployeeAccessAggregate.ApiHandler(kdbClient: kdbClient, roleDirectory: directory)

        let output = try await handler.checkPermissionHolders(.init(
            headers: .init(operatorId: "operator"),
            body: .json(.init(permission: permission, userIds: ["any-user"]))
        ))

        guard case .unprocessableContent(let response) = output else {
            Issue.record("expected 422, got \(output)")
            return
        }
        #expect(try response.body.json.error == .invalidPayload)
    }

    // 空 userIds → 200 { holders: [] }
    @Test func handler_returns_200_with_empty_holders_for_empty_userIds() async throws {
        let handler = EmployeeAccessAggregate.ApiHandler(kdbClient: kdbClient, roleDirectory: directory)

        let output = try await handler.checkPermissionHolders(.init(
            headers: .init(operatorId: "operator"),
            body: .json(.init(permission: "Any.Permission", userIds: []))
        ))

        guard case .ok(let response) = output else {
            Issue.record("expected 200, got \(output)")
            return
        }
        #expect(try response.body.json.holders.isEmpty)
    }

    // MARK: - helpers

    private func createRole(bundle: TestBundle, operatorId: String, permissions: [String]) async throws -> String {
        let output = try await CreateRoleService(repository: roleRepository).execute(input: .init(
            name: await bundle.generateId(for: "roleName"),
            description: "permission-holder-check test",
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
    private func seedEmployee(bundle: TestBundle, operatorId: String, roles: [String] = []) async throws -> (employeeAccessId: String, userId: String) {
        let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
        let userId = await bundle.generateId(for: "userId")
        try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)
        if !roles.isEmpty {
            _ = try await AssignRolesService(repository: repository, roleDirectory: directory).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, roles: roles, operatorId: operatorId
            ))
        }
        return (employeeAccessId, userId)
    }

    private func grant(employeeAccessId: String, userId: String, permissions: [String], operatorId: String) async throws {
        _ = try await GrantPrivilegeService(repository: repository, effectivePermissionsReader: timeline).execute(input: .init(
            employeeAccessId: employeeAccessId, userId: userId, permissions: permissions, operatorId: operatorId
        ))
    }

    private func revoke(employeeAccessId: String, userId: String, permissions: [String], operatorId: String) async throws {
        _ = try await RevokePrivilegeService(repository: repository, effectivePermissionsReader: timeline).execute(input: .init(
            employeeAccessId: employeeAccessId, userId: userId, permissions: permissions, operatorId: operatorId
        ))
    }

    private func catalogPermission(at index: Int) -> String {
        let sorted = PermissionCatalog.allRawValues.sorted()
        return sorted[index % sorted.count]
    }

    private func waitForProjection() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }
}
