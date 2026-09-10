import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

@Suite(.serialized)
struct AssignRolesIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let repository: EmployeeAccessRepository

    init() {
        self.repository = EmployeeAccessRepository(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
    }

    // happy：新人 roles 空 → assign ["dev"] → 聯集加入。
    @Test func assign_new_role_succeeds() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)

            _ = try await AssignRolesService(repository: repository).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, roles: ["dev"], operatorId: operatorId
            ))
            let aggregate = try #require(try await repository.find(byId: employeeAccessId))
            #expect(aggregate.roles?.contains("dev") == true)
        }
    }

    // guard：assign 同一 role 兩次 → 第二次 roleAlreadyExists（act-sequence）。
    @Test func assign_existing_role_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, repository: repository)

            let usecase = AssignRolesService(repository: repository)
            _ = try await usecase.execute(input: .init(   // 第一次：成功前置
                employeeAccessId: employeeAccessId, userId: userId, roles: ["dev"], operatorId: operatorId
            ))
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: AssignRolesOutput = try await usecase.execute(input: .init(   // 第二次：觸發
                    employeeAccessId: employeeAccessId, userId: userId, roles: ["dev"], operatorId: operatorId
                ))
            }
            #expect(error?.error == .roleAlreadyExists)
        }
    }

    // infra：目標 profile 不存在 → aggregateNotFound。
    @Test func assign_missing_profile_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let usecase = AssignRolesService(repository: repository)
            let error = await #expect(throws: DDDError.self) {
                let _: AssignRolesOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, roles: ["dev"], operatorId: operatorId
                ))
            }
            #expect(error?.code == .aggregateNotFound)
        }
    }
}
