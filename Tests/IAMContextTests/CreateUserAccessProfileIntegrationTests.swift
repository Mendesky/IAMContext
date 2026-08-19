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
                employeeAccessId: employeeAccessId, userId: userId, department: "資訊部門", jobTitle: "組員", operatorId: operatorId, firm: "正大會計師事務所"
            ))
            #expect(output.id == employeeAccessId)
            let aggregate = try #require(try await repository.find(byId: employeeAccessId))
            #expect(aggregate.userId == userId)
            #expect(aggregate.status == .Active)
            #expect(aggregate.permissions?.isEmpty == true)
        }
    }

    // (b) create 帶 firm → 成功（firm 欄位被保存）
    @Test func create_with_firm_succeeds() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let output = try await CreateUserAccessProfileService(repository: repository).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, department: "資訊部門", jobTitle: "組員", operatorId: operatorId, firm: "正大聯合會計師事務所"
            ))
            #expect(output.id == employeeAccessId)
            let aggregate = try #require(try await repository.find(byId: employeeAccessId))
            #expect(aggregate.firm == "正大聯合會計師事務所")
        }
    }

    // (a) create 無 firm（nil）→ firmRequired
    @Test func create_nil_firm_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let usecase = CreateUserAccessProfileService(repository: repository)
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: CreateUserAccessProfileOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, department: "資訊部門", jobTitle: "組員", operatorId: operatorId, firm: nil
                ))
            }
            #expect(error?.error == .firmRequired)
        }
    }

    // (a) create firm 為空字串 → firmRequired
    @Test func create_empty_firm_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let usecase = CreateUserAccessProfileService(repository: repository)
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: CreateUserAccessProfileOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, department: "資訊部門", jobTitle: "組員", operatorId: operatorId, firm: ""
                ))
            }
            #expect(error?.error == .firmRequired)
        }
    }

    // (c) 舊事件（firm == nil）rehydrate → aggregate.firm 為 nil，不報錯
    @Test func rehydrate_without_firm_succeeds() throws {
        // 直接用 createdEvent 建構 aggregate，模擬從無 firm 的舊事件重播
        let oldEvent = UserAccessProfileCreated(
            employeeAccessId: "legacy-id-001",
            userId: "user-001",
            department: "資訊部門",
            jobTitle: "組員",
            permissions: [],
            roles: [],
            status: .Active,
            firm: nil,        // 舊事件無 firm
            occurred: .now
        )
        // 不應 throw
        let aggregate = try #require(try EmployeeAccess(first: oldEvent, other: []))
        #expect(aggregate.firm == nil)
        #expect(aggregate.userId == "user-001")
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
                employeeAccessId: employeeAccessId, userId: userId, department: "資訊部門", jobTitle: "組員", operatorId: operatorId, firm: "正大會計師事務所"
            ))
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: CreateUserAccessProfileOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, department: "資訊部門", jobTitle: "組員", operatorId: operatorId, firm: "正大會計師事務所"
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
                    employeeAccessId: employeeAccessId, userId: "", department: "資訊部門", jobTitle: "組員", operatorId: operatorId, firm: "正大會計師事務所"
                ))
            }
            #expect(error?.error == .userIdNotExist)
        }
    }
}
