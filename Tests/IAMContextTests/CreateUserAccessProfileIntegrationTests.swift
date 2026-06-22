import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

// 整合層 test（Service + repository + withTestBundle，需 localhost KurrentDB）。
// 適配版：不用 GenesisTODO（domain 已填）→ 直接寫成會綠的整合 test。

@Suite(.serialized)
struct CreateUserAccessProfileIntegrationTests {
    let kdbClient: KurrentDBClient = .init(settings: .localhost())
    let repository: EmployeeAccessRepository

    init() {
        self.repository = EmployeeAccessRepository(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
    }

    @Test func create_happy() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let output = try await CreateUserAccessProfileService(repository: repository).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, department: "資訊部門", jobTitle: "組員", operatorId: operatorId
            ))
            #expect(output.id == employeeAccessId)
            let aggregate = try #require(try await repository.find(byId: employeeAccessId))
            #expect(aggregate.userId == userId)
            #expect(aggregate.status == .Active)
            #expect(aggregate.permissions?.isEmpty == true)
        }
    }

    // guard（code review 2026-06-12）：同一 employeeAccessId 重複 create → profileAlreadyExists
    // （避免第二個 createdEvent 被 .any expectedRevision 灌進既有 stream）。
    @Test func create_duplicate_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let usecase = CreateUserAccessProfileService(repository: repository)
            _ = try await usecase.execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, department: "資訊部門", jobTitle: "組員", operatorId: operatorId
            ))
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: CreateUserAccessProfileOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, department: "資訊部門", jobTitle: "組員", operatorId: operatorId
                ))
            }
            #expect(error?.error == .profileAlreadyExists)
        }
    }

    @Test func create_empty_userId_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let operatorId = await bundle.generateId(for: "operatorId")
            let usecase = CreateUserAccessProfileService(repository: repository)
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: CreateUserAccessProfileOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: "", department: "資訊部門", jobTitle: "組員", operatorId: operatorId
                ))
            }
            #expect(error?.error == .userIdNotExist)
        }
    }
}
