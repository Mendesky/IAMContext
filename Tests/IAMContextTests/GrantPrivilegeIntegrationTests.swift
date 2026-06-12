import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

@Suite(.serialized)
struct GrantPrivilegeIntegrationTests {
    let kdbClient: KurrentDBClient = .init(settings: .localhost())
    let repository: EmployeeAccessRepository

    init() {
        self.repository = EmployeeAccessRepository(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
    }

    // happy：create 給 allPermissions，所以授一個「不在 allPermissions」的權限才會成功（去重 union）。
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

    // guard：授一個已存在的權限（在 allPermissions＝OC 153 內）→ permissionAlreadyExists。
    // 註：allPermissions 已從舊 placeholder（含 it:read）換成 OC 權威 153 條，故改用真實存在的權限字串。
    @Test func grant_existing_privilege_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)

            let usecase = GrantPrivilegeService(repository: repository)
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
