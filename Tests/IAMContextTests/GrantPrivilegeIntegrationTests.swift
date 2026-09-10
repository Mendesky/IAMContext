import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

@Suite(.serialized)
struct GrantPrivilegeIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let repository: EmployeeAccessRepository

    init() {
        self.repository = EmployeeAccessRepository(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
    }

    // happy：create 給空權限，授一條新權限 → 成功（union 加入）。
    @Test func grant_new_privilege_succeeds() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)

            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, permissions: ["custom:new"], operatorId: operatorId
            ))
            let aggregate = try #require(try await repository.find(byId: employeeAccessId))
            #expect(aggregate.permissions?.contains("custom:new") == true)
        }
    }

    // guard：授一個「已存在」的權限 → permissionAlreadyExists。create 現在給空權限，故先 grant 一條，再重複 grant 同一條。
    @Test func grant_existing_privilege_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)

            let usecase = GrantPrivilegeService(repository: repository)
            // 先授一條使其存在
            _ = try await usecase.execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, permissions: ["OpportunityContext.AuditQuoting.AddAccounting"], operatorId: operatorId
            ))
            // 再授同一條 → permissionAlreadyExists
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: GrantPrivilegeOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, permissions: ["OpportunityContext.AuditQuoting.AddAccounting"], operatorId: operatorId
                ))
            }
            #expect(error?.error == .permissionAlreadyExists)
        }
    }

    // guard（code review 2026-06-12）：請求帶的 userId 與 profile 真正的 userId 不一致 → userIdMismatch
    // （防止把權限事件灌進別人的身分、污染 GetPermissions 投影）。
    @Test func grant_userId_mismatch_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let wrongUserId = await bundle.generateId(for: "wrongUserId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)

            let usecase = GrantPrivilegeService(repository: repository)
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: GrantPrivilegeOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: wrongUserId, permissions: ["custom:new"], operatorId: operatorId
                ))
            }
            #expect(error?.error == .userIdMismatch)
        }
    }

    // infra：目標 profile 不存在 → DDDError.aggregateNotFound。
    @Test func grant_missing_profile_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)   // 未 seed
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let usecase = GrantPrivilegeService(repository: repository)
            let error = await #expect(throws: DDDError.self) {
                let _: GrantPrivilegeOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, permissions: ["it:read"], operatorId: operatorId
                ))
            }
            #expect(error?.code == .aggregateNotFound)
        }
    }
}
