import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

@Suite(.serialized)
struct PromoteUserIntegrationTests {
    let kdbClient: KurrentDBClient = makeTestKurrentDBClient()
    let repository: EmployeeAccessRepository

    init() {
        self.repository = EmployeeAccessRepository(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
    }

    // happy：seed 為 組員 → promote 到 組長 → jobTitle 更新。
    @Test func promote_succeeds() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, department: "資訊部門", jobTitle: "組員", repository: repository)

            _ = try await PromoteUserService(repository: repository).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, newJobTitle: "組長", oldJobTitle: "組員", operatorId: operatorId
            ))
            let aggregate = try #require(try await repository.find(byId: employeeAccessId))
            #expect(aggregate.jobTitle == "組長")
        }
    }

    // infra：目標 profile 不存在 → aggregateNotFound。
    @Test func promote_missing_profile_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let usecase = PromoteUserService(repository: repository)
            let error = await #expect(throws: DDDError.self) {
                let _: PromoteUserOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, newJobTitle: "組長", oldJobTitle: "組員", operatorId: operatorId
                ))
            }
            #expect(error?.code == .aggregateNotFound)
        }
    }

    // 註：employeeNotActive scenario 在現有模型下無法觸發（無 resign event；ensureInvariant 也擋不住建構），故不寫。
}
