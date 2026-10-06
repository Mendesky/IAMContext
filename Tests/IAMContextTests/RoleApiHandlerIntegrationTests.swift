import Testing
import Foundation
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared
import IAMPermissionCatalog
import RoleAggregate

// 角色 HTTP 層（RoleAggregate.ApiHandler ＋ EmployeeAccessAggregate.ApiHandler 的角色相關端點）整合測試。
//
// 既有角色測試（RoleIntegrationTests 等）都直接呼叫 service，沒經過 ApiHandler，
// 所以「request 解析」與「錯誤碼對應（422／404）」沒被保護。這裡直接呼叫 handler 方法，
// 斷言回傳的 Output case 與 error 列舉值；對外承諾以 docs/integration/2026-09-24-role-api-update.html 的錯誤碼表為準。
//
// 兩個 module 都有 `Operations` / `Components`（同名 package 型別），所以這裡一律不寫型別名，
// 讓 handler 參數型別驅動 `.init(...)` 推斷。
//
// 前提：KurrentDB localhost:2113；projection IAM_GetRoles / IAM_RoleHolders 已部署。
// - 角色寫入與單一角色權限查詢是強一致（rehydrate），不等待。
// - GET /roles 與 role-holders 走 projection → waitForProjection()（寫法比照 RoleIntegrationTests）。
// - 每個測試自己用 bundle.generateId 產唯一的角色名與 id，不依賴、也不污染本機既有資料。
@Suite(.serialized)
struct RoleApiHandlerIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let roleApi: RoleAggregate.ApiHandler
    let employeeAccessApi: EmployeeAccessAggregate.ApiHandler
    let employeeAccessRepository: EmployeeAccessRepository

    init() {
        self.roleApi = RoleAggregate.ApiHandler(kdbClient: kdbClient)
        self.employeeAccessApi = EmployeeAccessAggregate.ApiHandler(
            kdbClient: kdbClient,
            roleDirectory: RoleAggregateDirectory(kdbClient: kdbClient)
        )
        self.employeeAccessRepository = EmployeeAccessRepository(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
    }

    // MARK: - createRole

    @Test func create_role_returns_200_with_generated_roleId() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let name = await bundle.generateId(for: "roleName")

            let output = try await roleApi.createRole(.init(
                headers: .init(operatorId: operatorId),
                body: .json(.init(name: name, description: "api handler test"))
            ))

            guard case .ok(let ok) = output else {
                Issue.record("expected 200, got \(output)")
                return
            }
            #expect(UUID(uuidString: try ok.body.json.roleId) != nil)
        }
    }

    @Test func create_role_with_empty_name_returns_422_roleNameRequired() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")

            let output = try await roleApi.createRole(.init(
                headers: .init(operatorId: operatorId),
                body: .json(.init(name: "", description: nil))
            ))

            guard case .unprocessableContent(let response) = output else {
                Issue.record("expected 422, got \(output)")
                return
            }
            #expect(try response.body.json.error == .roleNameRequired)
        }
    }

    // 對外承諾（docs 錯誤碼表）：roleNameRequired 的觸發條件是「name 為空**或全空白**」。
    @Test func create_role_with_whitespace_only_name_returns_422_roleNameRequired() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")

            let output = try await roleApi.createRole(.init(
                headers: .init(operatorId: operatorId),
                body: .json(.init(name: "   ", description: nil))
            ))

            switch output {
            case .unprocessableContent(let response):
                #expect(try response.body.json.error == .roleNameRequired)
            case .ok(let ok):
                Issue.record("expected 422 roleNameRequired for whitespace-only name, but the role was created (200)")
                // 善後：刪掉誤建的空白名角色，避免污染本機資料（否則下一輪會變成 roleNameDuplicated，結果不可重現）。
                _ = try await roleApi.deleteRole(.init(
                    path: .init(roleId: try ok.body.json.roleId),
                    headers: .init(operatorId: operatorId)
                ))
                try await waitForProjection()
            default:
                Issue.record("expected 422, got \(output)")
            }
        }
    }

    @Test func create_role_with_duplicate_name_returns_422_roleNameDuplicated() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let name = await bundle.generateId(for: "roleName")
            _ = try await createRoleId(name: name, operatorId: operatorId)
            try await waitForProjection()   // 同名檢查讀 GetRoles projection（盡力檢查、最終一致）

            let output = try await roleApi.createRole(.init(
                headers: .init(operatorId: operatorId),
                body: .json(.init(name: name, description: "duplicate"))
            ))

            guard case .unprocessableContent(let response) = output else {
                Issue.record("expected 422, got \(output)")
                return
            }
            #expect(try response.body.json.error == .roleNameDuplicated)
        }
    }

    // MARK: - addPermissions

    @Test func add_permissions_with_rawValue_outside_catalog_returns_422_invalidPermission() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRoleId(name: await bundle.generateId(for: "roleName"), operatorId: operatorId)

            let output = try await roleApi.addPermissions(.init(
                path: .init(roleId: roleId),
                headers: .init(operatorId: operatorId),
                body: .json(.init(permissions: [catalogPermissions(count: 1)[0], "Nope.Not.Real"]))
            ))

            guard case .unprocessableContent(let response) = output else {
                Issue.record("expected 422, got \(output)")
                return
            }
            #expect(try response.body.json.error == .invalidPermission)

            // 整批拒絕：合法的那個也沒有被加進去。
            let permissions = try await rolePermissions(roleId: roleId)
            #expect(permissions.isEmpty)
        }
    }

    @Test func add_permissions_with_net_empty_effect_returns_422_permissionsUnchanged() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRoleId(name: await bundle.generateId(for: "roleName"), operatorId: operatorId)
            let permissions = catalogPermissions(count: 2)

            let first = try await roleApi.addPermissions(.init(
                path: .init(roleId: roleId),
                headers: .init(operatorId: operatorId),
                body: .json(.init(permissions: permissions))
            ))
            guard case .ok = first else {
                Issue.record("expected 200 on first add, got \(first)")
                return
            }

            // 全部都已存在 → 扣掉已有的之後沒有東西可加。
            let second = try await roleApi.addPermissions(.init(
                path: .init(roleId: roleId),
                headers: .init(operatorId: operatorId),
                body: .json(.init(permissions: permissions))
            ))
            guard case .unprocessableContent(let response) = second else {
                Issue.record("expected 422, got \(second)")
                return
            }
            #expect(try response.body.json.error == .permissionsUnchanged)
        }
    }

    // MARK: - 404：roleId 不存在或已刪除

    @Test func rename_role_with_unknown_roleId_returns_404() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")

            let output = try await roleApi.renameRole(.init(
                path: .init(roleId: UUID().uuidString),
                headers: .init(operatorId: operatorId),
                body: .json(.init(newName: await bundle.generateId(for: "newRoleName")))
            ))

            guard case .notFound(let response) = output else {
                Issue.record("expected 404, got \(output)")
                return
            }
            #expect(try response.body.json.error == .aggregateNotFound)
        }
    }

    // 改名沒有 usecase 層檢查，靠 Role.ensureInvariant()（去除空白後不可為空）。
    // 同時驗證失敗的改名沒有把事件寫進 stream：之後角色仍可 rehydrate（getRolePermissions 回 200）。
    @Test func rename_role_to_whitespace_only_name_returns_422_and_leaves_role_intact() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRoleId(name: await bundle.generateId(for: "roleName"), operatorId: operatorId)

            let output = try await roleApi.renameRole(.init(
                path: .init(roleId: roleId),
                headers: .init(operatorId: operatorId),
                body: .json(.init(newName: "   "))
            ))

            guard case .unprocessableContent(let response) = output else {
                Issue.record("expected 422 roleNameRequired, got \(output)")
                return
            }
            #expect(try response.body.json.error == .roleNameRequired)

            let after = try await roleApi.getRolePermissions(.init(path: .init(roleId: roleId)))
            guard case .ok = after else {
                Issue.record("role should still rehydrate after a rejected rename, got \(after)")
                return
            }
        }
    }

    @Test func get_role_permissions_with_unknown_roleId_returns_404() async throws {
        let output = try await roleApi.getRolePermissions(.init(path: .init(roleId: UUID().uuidString)))

        guard case .notFound(let response) = output else {
            Issue.record("expected 404, got \(output)")
            return
        }
        #expect(try response.body.json.error == .aggregateNotFound)
    }

    @Test func get_role_permissions_after_delete_role_returns_404() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRoleId(name: await bundle.generateId(for: "roleName"), operatorId: operatorId)

            let deleted = try await roleApi.deleteRole(.init(
                path: .init(roleId: roleId),
                headers: .init(operatorId: operatorId)
            ))
            guard case .ok(let ok) = deleted else {
                Issue.record("expected 200 on delete, got \(deleted)")
                return
            }
            #expect(try ok.body.json.roleId == roleId)

            // 強一致：刪除成功後立刻查單一角色權限即 404。
            let output = try await roleApi.getRolePermissions(.init(path: .init(roleId: roleId)))
            guard case .notFound(let response) = output else {
                Issue.record("expected 404, got \(output)")
                return
            }
            #expect(try response.body.json.error == .aggregateNotFound)
        }
    }

    // MARK: - getRoles / getRolePermissions 成功路徑

    @Test func get_roles_returns_200_and_created_role_carries_its_permissions() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let name = await bundle.generateId(for: "roleName")
            let permissions = catalogPermissions(count: 2)
            let roleId = try await createRoleId(name: name, operatorId: operatorId)
            let added = try await roleApi.addPermissions(.init(
                path: .init(roleId: roleId),
                headers: .init(operatorId: operatorId),
                body: .json(.init(permissions: permissions))
            ))
            guard case .ok = added else {
                Issue.record("expected 200 on add, got \(added)")
                return
            }

            // 單一角色權限：強一致，不等待。
            #expect(Set(try await rolePermissions(roleId: roleId)) == Set(permissions))

            // 清單：projection，最終一致。
            try await waitForProjection()
            let output = try await roleApi.getRoles(.init())
            guard case .ok(let ok) = output else {
                Issue.record("expected 200, got \(output)")
                return
            }
            let summary = try #require(try ok.body.json.first { $0.roleId == roleId })
            #expect(summary.name == name)
            #expect(Set(summary.permissions) == Set(permissions))
        }
    }

    // MARK: - EmployeeAccess：assignRoles / getRoleHolders

    @Test func assign_roles_with_unknown_roleId_returns_422_roleNotFound() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let (employeeAccessId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId)

            let output = try await employeeAccessApi.assignRoles(.init(
                path: .init(employeeAccessId: employeeAccessId),
                headers: .init(operatorId: operatorId),
                body: .json(.init(userId: userId, roles: [UUID().uuidString]))
            ))

            guard case .unprocessableContent(let response) = output else {
                Issue.record("expected 422, got \(output)")
                return
            }
            #expect(try response.body.json.error == .roleNotFound)
        }
    }

    @Test func get_role_holders_after_assign_roles_returns_200_containing_userId() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let operatorId = await bundle.generateId(for: "operatorId")
            let roleId = try await createRoleId(name: await bundle.generateId(for: "roleName"), operatorId: operatorId)
            let (employeeAccessId, userId) = try await seedEmployee(bundle: bundle, operatorId: operatorId)

            let assigned = try await employeeAccessApi.assignRoles(.init(
                path: .init(employeeAccessId: employeeAccessId),
                headers: .init(operatorId: operatorId),
                body: .json(.init(userId: userId, roles: [roleId]))
            ))
            guard case .ok = assigned else {
                Issue.record("expected 200 on assign, got \(assigned)")
                return
            }
            try await waitForProjection()

            let output = try await employeeAccessApi.getRoleHolders(.init(query: .init(role: roleId)))
            guard case .ok(let ok) = output else {
                Issue.record("expected 200, got \(output)")
                return
            }
            #expect(try ok.body.json.contains(userId))
        }
    }

    @Test func get_role_holders_with_unknown_roleId_returns_200_with_empty_array() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let unknownRoleId = await bundle.generateId(for: "unknownRole")

            let output = try await employeeAccessApi.getRoleHolders(.init(query: .init(role: unknownRoleId)))

            guard case .ok(let ok) = output else {
                Issue.record("expected 200, got \(output)")
                return
            }
            #expect(try ok.body.json.isEmpty)
        }
    }

    // MARK: - helpers

    /// 經 HTTP 層建立角色並回傳 roleId（順便驗證 200）。
    private func createRoleId(name: String, operatorId: String) async throws -> String {
        let output = try await roleApi.createRole(.init(
            headers: .init(operatorId: operatorId),
            body: .json(.init(name: name, description: "api handler test"))
        ))
        guard case .ok(let ok) = output else {
            Issue.record("setup: expected createRole 200, got \(output)")
            throw SetupFailure()
        }
        return try ok.body.json.roleId
    }

    /// 經 HTTP 層查單一角色權限（強一致）；非 200 視為測試 setup 失敗。
    private func rolePermissions(roleId: String) async throws -> [String] {
        let output = try await roleApi.getRolePermissions(.init(path: .init(roleId: roleId)))
        guard case .ok(let ok) = output else {
            Issue.record("expected getRolePermissions 200, got \(output)")
            throw SetupFailure()
        }
        return try ok.body.json
    }

    /// 建 active profile（不指派角色；指派由各測試經 HTTP 層做）。
    private func seedEmployee(bundle: TestBundle, operatorId: String) async throws -> (employeeAccessId: String, userId: String) {
        let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
        let userId = await bundle.generateId(for: "userId")
        try await seedActiveProfile(
            employeeAccessId: employeeAccessId,
            userId: userId,
            operatorId: operatorId,
            repository: employeeAccessRepository
        )
        return (employeeAccessId, userId)
    }

    private func catalogPermissions(count: Int) -> [String] {
        Array(PermissionCatalog.allRawValues.sorted().prefix(count))
    }

    private func waitForProjection() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    private struct SetupFailure: Error {}
}
