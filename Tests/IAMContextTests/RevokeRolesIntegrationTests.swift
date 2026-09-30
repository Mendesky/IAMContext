import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

@Suite(.serialized)
struct RevokeRolesIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let repository: EmployeeAccessRepository

    init() {
        self.repository = EmployeeAccessRepository(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
    }

    // happy：先 assign ["dev"] 再 revoke ["dev"] → 差集移除。
    @Test func revoke_existing_role_succeeds() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)
            _ = try await AssignRolesService(repository: repository, roleDirectory: FakeRoleDirectory()).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, roles: ["dev"], operatorId: operatorId
            ))

            _ = try await RevokeRolesService(repository: repository).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, roles: ["dev"], operatorId: operatorId
            ))
            let aggregate = try #require(try await repository.find(byId: employeeAccessId))
            #expect(aggregate.roles?.contains("dev") == false)
        }
    }

    // guard：撤一個 user 沒有的 role（新人 roles 空）→ roleNotExist。
    @Test func revoke_missing_role_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)

            let usecase = RevokeRolesService(repository: repository)
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: RevokeRolesOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, roles: ["dev"], operatorId: operatorId
                ))
            }
            #expect(error?.error == .roleNotExist)
        }
    }

    // infra：目標 profile 不存在 → aggregateNotFound。
    @Test func revoke_missing_profile_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let usecase = RevokeRolesService(repository: repository)
            let error = await #expect(throws: DDDError.self) {
                let _: RevokeRolesOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, roles: ["dev"], operatorId: operatorId
                ))
            }
            #expect(error?.code == .aggregateNotFound)
        }
    }
}
