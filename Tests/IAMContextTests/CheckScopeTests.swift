import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

// 授權範圍判斷（scope-check）整合測試：CheckScopeApplicationService。
// 涵蓋 spec docs/tasks/2026-09-03-firm-format-and-scope-check.md 驗收標準列的 5 個案例。
//
// 備註：scope-check 不看 permission，只看「userId 是否存在於 IAM 且落在 department/firm 範圍內」，
// 所以測試起點只需 seedActiveProfile，不需 grant 任何權限（與 GetPermissionHoldersIntegrationTests 不同）。
@Suite(.serialized)
struct CheckScopeTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let repository: EmployeeAccessRepository

    init() {
        self.repository = EmployeeAccessRepository(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
    }

    // 案例 1：userIds 中部分在範圍、部分不在 → 只回在範圍者
    @Test func partial_match_returns_only_in_scope_userIds() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId1 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let eaId2 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId1 = await bundle.generateId(for: "userId1")
            let userId2 = await bundle.generateId(for: "userId2")
            let operatorId = await bundle.generateId(for: "operatorId")

            // userId1 屬「審1／台北所」，userId2 屬「審2／台北所」
            try await seedActiveProfile(employeeAccessId: eaId1, userId: userId1, operatorId: operatorId, department: "審1", firm: "台北所", repository: repository)
            try await seedActiveProfile(employeeAccessId: eaId2, userId: userId2, operatorId: operatorId, department: "審2", firm: "台北所", repository: repository)

            // 等 KDB projection 完成 link（IAM_GetPermissionsProjection.js 非同步，同 GetPermissionHoldersIntegrationTests 慣例）。
            try await Task.sleep(for: .milliseconds(500))

            let service = CheckScopeApplicationService(kdbClient: kdbClient)
            let output = try await service.execute(input: .init(userIds: [userId1, userId2], firm: nil, department: "審1"))

            #expect(output.inScope.contains(userId1), "userId1（審1）應在範圍內")
            #expect(!output.inScope.contains(userId2), "userId2（審2）不應在範圍內")
        }
    }

    // 案例 2：firm 與 department 皆 nil → 回全部（存在於 IAM 者）
    @Test func nil_firm_and_department_returns_all_existing_userIds() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId1 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let eaId2 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId1 = await bundle.generateId(for: "userId1")
            let userId2 = await bundle.generateId(for: "userId2")
            let operatorId = await bundle.generateId(for: "operatorId")

            try await seedActiveProfile(employeeAccessId: eaId1, userId: userId1, operatorId: operatorId, department: "審1", firm: "台北所", repository: repository)
            try await seedActiveProfile(employeeAccessId: eaId2, userId: userId2, operatorId: operatorId, department: "審2", firm: "台中所", repository: repository)

            try await Task.sleep(for: .milliseconds(500))

            let service = CheckScopeApplicationService(kdbClient: kdbClient)
            let output = try await service.execute(input: .init(userIds: [userId1, userId2], firm: nil, department: nil))

            #expect(output.inScope.contains(userId1), "未限縮時 userId1 應存在")
            #expect(output.inScope.contains(userId2), "未限縮時 userId2 應存在")
        }
    }

    // 案例 3：只給 firm / 只給 department → 各自正確限縮
    @Test func firm_only_and_department_only_each_scope_correctly() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId1 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let eaId2 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId1 = await bundle.generateId(for: "userId1")
            let userId2 = await bundle.generateId(for: "userId2")
            let operatorId = await bundle.generateId(for: "operatorId")

            // userId1: 台北所 + 審1；userId2: 台中所 + 審2
            try await seedActiveProfile(employeeAccessId: eaId1, userId: userId1, operatorId: operatorId, department: "審1", firm: "台北所", repository: repository)
            try await seedActiveProfile(employeeAccessId: eaId2, userId: userId2, operatorId: operatorId, department: "審2", firm: "台中所", repository: repository)

            try await Task.sleep(for: .milliseconds(500))

            let service = CheckScopeApplicationService(kdbClient: kdbClient)

            // 只給 firm=台北所 → 只回 userId1
            let byFirm = try await service.execute(input: .init(userIds: [userId1, userId2], firm: "台北所", department: nil))
            #expect(byFirm.inScope.contains(userId1), "userId1（台北所）應在範圍內")
            #expect(!byFirm.inScope.contains(userId2), "userId2（台中所）不應在範圍內")

            // 只給 department=審2 → 只回 userId2
            let byDepartment = try await service.execute(input: .init(userIds: [userId1, userId2], firm: nil, department: "審2"))
            #expect(!byDepartment.inScope.contains(userId1), "userId1（審1）不應在範圍內")
            #expect(byDepartment.inScope.contains(userId2), "userId2（審2）應在範圍內")
        }
    }

    // 案例 4：userIds 含 IAM 查無此人的 id → 靜默排除，不拋錯
    @Test func unknown_userId_is_silently_excluded() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let eaId1 = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId1 = await bundle.generateId(for: "userId1")
            let unknownUserId = await bundle.generateId(for: "unknownUserId")
            let operatorId = await bundle.generateId(for: "operatorId")

            try await seedActiveProfile(employeeAccessId: eaId1, userId: userId1, operatorId: operatorId, repository: repository)

            try await Task.sleep(for: .milliseconds(500))

            let service = CheckScopeApplicationService(kdbClient: kdbClient)
            let output = try await service.execute(input: .init(userIds: [userId1, unknownUserId], firm: nil, department: nil))

            #expect(output.inScope.contains(userId1), "存在的 userId1 應在範圍內")
            #expect(!output.inScope.contains(unknownUserId), "查無此人的 userId 應被靜默排除，而非拋錯")
        }
    }

    // 案例 5：userIds 為空 → 回空陣列
    @Test func empty_userIds_returns_empty_array() async throws {
        let service = CheckScopeApplicationService(kdbClient: kdbClient)
        let output = try await service.execute(input: .init(userIds: [], firm: nil, department: nil))
        #expect(output.inScope.isEmpty, "空輸入應回空陣列，不拋錯")
    }
}
