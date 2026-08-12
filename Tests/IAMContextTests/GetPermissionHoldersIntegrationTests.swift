import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

// 反查整合測試：GetPermissionHoldersApplicationService。
//
// 前提：KDB `IAM_PermissionHoldersProjection.js` 已部署（Continuous Projection）。
// 若 projection 未部署，per-permission stream 永遠為空 → service 回 []。
// happy-path（grant 後出現 / revoke 後消失）需 projection 已部署 + 事件 ingest。
//
// 備註：這批測試直接寫事件到 KDB（透過 GrantPrivilegeService / RevokePrivilegeService），
//       測試的是 application service 端的投影讀取行為。KDB projection 非同步 link，
//       因此測試以 `Task.sleep` 等待 projection 完成（demo 環境可接受）。
@Suite(.serialized)
struct GetPermissionHoldersIntegrationTests {
    let kdbClient: KurrentDBClient = .init(settings: .localhost())
    let repository: EmployeeAccessRepository

    init() {
        self.repository = EmployeeAccessRepository(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
    }

    // happy path：
    // 1. 建兩個 user access profile
    // 2. 兩個 userId 都 grant 同一個 permission rawValue
    // 3. revoke 其中一個 userId 的該 permission
    // 4. 端點回傳只剩未被 revoke 的那個 userId
    @Test func grant_then_revoke_returns_only_active_holders() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let permission = "OpportunityContext.Handover.AllocateForTaipei"

            // 建立兩個 user profile
            let eaId1 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let eaId2 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId1 = await bundle.generateId(for: "userId1")
            let userId2 = await bundle.generateId(for: "userId2")
            let operatorId = await bundle.generateId(for: "operatorId")

            try await seedActiveProfile(employeeAccessId: eaId1, userId: userId1, operatorId: operatorId, repository: repository)
            try await seedActiveProfile(employeeAccessId: eaId2, userId: userId2, operatorId: operatorId, repository: repository)

            // 兩個 userId 都 grant 同一個 permission
            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId1, userId: userId1, permissions: [permission], operatorId: operatorId
            ))
            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId2, userId: userId2, permissions: [permission], operatorId: operatorId
            ))

            // 等 KDB projection 完成 link（projection 非同步）
            try await Task.sleep(for: .milliseconds(500))

            // revoke userId1 的 permission
            _ = try await RevokePrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId1, userId: userId1, permissions: [permission], operatorId: operatorId
            ))

            // 等 projection 處理 revoke 事件
            try await Task.sleep(for: .milliseconds(500))

            // 只有 userId2 留在清單（userId1 已被 revoke）
            let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient)
            let holders = try await service.execute(input: .init(permission: permission))

            #expect(holders.contains(userId2), "userId2 should be in holders after grant")
            #expect(!holders.contains(userId1), "userId1 should NOT be in holders after revoke")
        }
    }

    // 邊界：無人持有的 permission rawValue → 回空陣列（而非 error）
    @Test func unknown_permission_returns_empty_array() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let unknownPermission = await bundle.generateId(for: "unknownPermission")
            let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient)
            let holders = try await service.execute(input: .init(permission: unknownPermission))
            #expect(holders.isEmpty, "unknown permission should return empty array, not throw")
        }
    }

    // department 過濾：不帶 department → 回全體持有者（向後相容）
    @Test func without_department_filter_returns_all_holders() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let permission = await bundle.generateId(for: "perm")
            let eaId1 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let eaId2 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId1 = await bundle.generateId(for: "userId1")
            let userId2 = await bundle.generateId(for: "userId2")
            let operatorId = await bundle.generateId(for: "operatorId")

            // userId1 屬「資訊部門」，userId2 屬「業務部門」
            try await seedActiveProfile(employeeAccessId: eaId1, userId: userId1, operatorId: operatorId, department: "資訊部門", repository: repository)
            try await seedActiveProfile(employeeAccessId: eaId2, userId: userId2, operatorId: operatorId, department: "業務部門", repository: repository)

            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId1, userId: userId1, permissions: [permission], operatorId: operatorId
            ))
            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId2, userId: userId2, permissions: [permission], operatorId: operatorId
            ))

            try await Task.sleep(for: .milliseconds(500))

            // 不帶 department → 全體持有者都回來
            let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient)
            let holders = try await service.execute(input: .init(permission: permission))
            #expect(holders.contains(userId1), "userId1 should appear when no department filter")
            #expect(holders.contains(userId2), "userId2 should appear when no department filter")
        }
    }

    // firm 過濾：不帶 firm → 回全體持有者（向後相容）
    @Test func without_firm_filter_returns_all_holders() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let permission = await bundle.generateId(for: "perm")
            let eaId1 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let eaId2 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId1 = await bundle.generateId(for: "userId1")
            let userId2 = await bundle.generateId(for: "userId2")
            let operatorId = await bundle.generateId(for: "operatorId")

            // userId1 屬「台北所」，userId2 屬「台中所」
            try await seedActiveProfile(employeeAccessId: eaId1, userId: userId1, operatorId: operatorId, firm: "台北所", repository: repository)
            try await seedActiveProfile(employeeAccessId: eaId2, userId: userId2, operatorId: operatorId, firm: "台中所", repository: repository)

            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId1, userId: userId1, permissions: [permission], operatorId: operatorId
            ))
            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId2, userId: userId2, permissions: [permission], operatorId: operatorId
            ))

            try await Task.sleep(for: .milliseconds(500))

            // 不帶 firm → 全體持有者都回來
            let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient)
            let holders = try await service.execute(input: .init(permission: permission))
            #expect(holders.contains(userId1), "userId1 should appear when no firm filter")
            #expect(holders.contains(userId2), "userId2 should appear when no firm filter")
        }
    }

    // firm 過濾：帶 firm → 只回該所別持有者
    @Test func with_firm_filter_returns_only_matching_firm_holders() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let permission = await bundle.generateId(for: "perm")
            let eaId1 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let eaId2 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId1 = await bundle.generateId(for: "userId1")
            let userId2 = await bundle.generateId(for: "userId2")
            let operatorId = await bundle.generateId(for: "operatorId")

            // userId1 屬「台北所」，userId2 屬「台中所」
            try await seedActiveProfile(employeeAccessId: eaId1, userId: userId1, operatorId: operatorId, firm: "台北所", repository: repository)
            try await seedActiveProfile(employeeAccessId: eaId2, userId: userId2, operatorId: operatorId, firm: "台中所", repository: repository)

            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId1, userId: userId1, permissions: [permission], operatorId: operatorId
            ))
            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId2, userId: userId2, permissions: [permission], operatorId: operatorId
            ))

            try await Task.sleep(for: .milliseconds(500))

            let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient)

            // 帶 firm=台北所 → 只回 userId1
            let holdersTP = try await service.execute(input: .init(permission: permission, firm: "台北所"))
            #expect(holdersTP.contains(userId1), "userId1 (台北所) should appear when filtering by 台北所")
            #expect(!holdersTP.contains(userId2), "userId2 (台中所) should NOT appear when filtering by 台北所")

            // 帶 firm=台中所 → 只回 userId2
            let holdersTZ = try await service.execute(input: .init(permission: permission, firm: "台中所"))
            #expect(!holdersTZ.contains(userId1), "userId1 (台北所) should NOT appear when filtering by 台中所")
            #expect(holdersTZ.contains(userId2), "userId2 (台中所) should appear when filtering by 台中所")
        }
    }

    // firm + department 同時過濾：交集篩選
    @Test func with_firm_and_department_filter_returns_intersection() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let permission = await bundle.generateId(for: "perm")
            let eaId1 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let eaId2 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let eaId3 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId1 = await bundle.generateId(for: "userId1")
            let userId2 = await bundle.generateId(for: "userId2")
            let userId3 = await bundle.generateId(for: "userId3")
            let operatorId = await bundle.generateId(for: "operatorId")

            // userId1: 台北所 + 資訊部門；userId2: 台北所 + 業務部門；userId3: 台中所 + 資訊部門
            try await seedActiveProfile(employeeAccessId: eaId1, userId: userId1, operatorId: operatorId, department: "資訊部門", firm: "台北所", repository: repository)
            try await seedActiveProfile(employeeAccessId: eaId2, userId: userId2, operatorId: operatorId, department: "業務部門", firm: "台北所", repository: repository)
            try await seedActiveProfile(employeeAccessId: eaId3, userId: userId3, operatorId: operatorId, department: "資訊部門", firm: "台中所", repository: repository)

            for (eaId, userId) in [(eaId1, userId1), (eaId2, userId2), (eaId3, userId3)] {
                _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                    employeeAccessId: eaId, userId: userId, permissions: [permission], operatorId: operatorId
                ))
            }

            try await Task.sleep(for: .milliseconds(500))

            let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient)

            // firm=台北所 + department=資訊部門 → 只有 userId1（交集）
            let holders = try await service.execute(input: .init(permission: permission, department: "資訊部門", firm: "台北所"))
            #expect(holders.contains(userId1), "userId1 (台北所+資訊部門) should appear")
            #expect(!holders.contains(userId2), "userId2 (台北所+業務部門) should NOT appear")
            #expect(!holders.contains(userId3), "userId3 (台中所+資訊部門) should NOT appear")
        }
    }

    // department 過濾：帶 department → 只回該部門持有者
    @Test func with_department_filter_returns_only_matching_department_holders() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let permission = await bundle.generateId(for: "perm")
            let eaId1 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let eaId2 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId1 = await bundle.generateId(for: "userId1")
            let userId2 = await bundle.generateId(for: "userId2")
            let operatorId = await bundle.generateId(for: "operatorId")

            // userId1 屬「資訊部門」，userId2 屬「業務部門」
            try await seedActiveProfile(employeeAccessId: eaId1, userId: userId1, operatorId: operatorId, department: "資訊部門", repository: repository)
            try await seedActiveProfile(employeeAccessId: eaId2, userId: userId2, operatorId: operatorId, department: "業務部門", repository: repository)

            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId1, userId: userId1, permissions: [permission], operatorId: operatorId
            ))
            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId2, userId: userId2, permissions: [permission], operatorId: operatorId
            ))

            try await Task.sleep(for: .milliseconds(500))

            let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient)

            // 帶 department=資訊部門 → 只回 userId1
            let holdersIT = try await service.execute(input: .init(permission: permission, department: "資訊部門"))
            #expect(holdersIT.contains(userId1), "userId1 (資訊部門) should appear when filtering by 資訊部門")
            #expect(!holdersIT.contains(userId2), "userId2 (業務部門) should NOT appear when filtering by 資訊部門")

            // 帶 department=業務部門 → 只回 userId2
            let holdersBiz = try await service.execute(input: .init(permission: permission, department: "業務部門"))
            #expect(!holdersBiz.contains(userId1), "userId1 (資訊部門) should NOT appear when filtering by 業務部門")
            #expect(holdersBiz.contains(userId2), "userId2 (業務部門) should appear when filtering by 業務部門")
        }
    }

    // 過濾 × 轉調：轉調後過濾必須反映「新」部門/所別——新的查得到、舊的查不到。
    // 覆蓋 GetPermissionsPresenter.when(DepartmentTransferred) 的 department/firm 追蹤（此前為 no-op）。
    @Test func transfer_then_filters_reflect_new_department_and_firm() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let permission = await bundle.generateId(for: "perm")
            let eaId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")

            // 建檔在「資訊部門 / 台北所」並授權
            try await seedActiveProfile(employeeAccessId: eaId, userId: userId, operatorId: operatorId, department: "資訊部門", firm: "台北所", repository: repository)
            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, permissions: [permission], operatorId: operatorId
            ))

            // 轉調到「業務部門 / 台中所」
            _ = try await TransferDepartmentService(repository: repository).execute(input: .init(
                employeeAccessId: eaId, userId: userId, newDepartment: "業務部門", newJobTitle: "組長", operatorId: operatorId, newFirm: "台中所"
            ))

            try await Task.sleep(for: .milliseconds(500))

            let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient)

            // 新部門 / 新所別過濾 → 查得到
            let newDept = try await service.execute(input: .init(permission: permission, department: "業務部門"))
            #expect(newDept.contains(userId), "轉調後以新部門過濾應查得到持有者")
            let newFirm = try await service.execute(input: .init(permission: permission, firm: "台中所"))
            #expect(newFirm.contains(userId), "轉調後以新所別過濾應查得到持有者")

            // 舊部門 / 舊所別過濾 → 查不到
            let oldDept = try await service.execute(input: .init(permission: permission, department: "資訊部門"))
            #expect(!oldDept.contains(userId), "轉調後以舊部門過濾不應查得到持有者")
            let oldFirm = try await service.execute(input: .init(permission: permission, firm: "台北所"))
            #expect(!oldFirm.contains(userId), "轉調後以舊所別過濾不應查得到持有者")
        }
    }
}
