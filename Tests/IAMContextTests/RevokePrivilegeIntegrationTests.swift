import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

@Suite(.serialized)
struct RevokePrivilegeIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let repository: EmployeeAccessRepository

    init() {
        self.repository = EmployeeAccessRepository(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
    }

    // happy：撤一個 user 已有的權限 → 差集移除。create 現在給空權限，故先 grant 一條再 revoke。
    @Test func revoke_existing_privilege_succeeds() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)
            _ = try await GrantPrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, permissions: ["OpportunityContext.AuditQuoting.AddAccounting"], operatorId: operatorId
            ))

            _ = try await RevokePrivilegeService(repository: repository).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, permissions: ["OpportunityContext.AuditQuoting.AddAccounting"], operatorId: operatorId
            ))
            let aggregate = try #require(try await repository.find(byId: employeeAccessId))
            #expect(aggregate.permissions?.contains("OpportunityContext.AuditQuoting.AddAccounting") == false)
        }
    }

    // guard：撤一個 user 沒有的權限（custom:new）→ permissionNotExist。
    @Test func revoke_missing_privilege_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)

            let usecase = RevokePrivilegeService(repository: repository)
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: RevokePrivilegeOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, permissions: ["custom:new"], operatorId: operatorId
                ))
            }
            #expect(error?.error == .permissionNotExist)
        }
    }

    // infra：目標 profile 不存在 → aggregateNotFound。
    @Test func revoke_missing_profile_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let usecase = RevokePrivilegeService(repository: repository)
            let error = await #expect(throws: DDDError.self) {
                let _: RevokePrivilegeOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, permissions: ["it:read"], operatorId: operatorId
                ))
            }
            #expect(error?.code == .aggregateNotFound)
        }
    }
}
