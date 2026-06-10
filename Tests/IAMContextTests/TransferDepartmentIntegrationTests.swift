import Testing
import DDDKit
import KurrentDB
import TestUtility
import EmployeeAccessAggregate
import IAMContextShared

@Suite(.serialized)
struct TransferDepartmentIntegrationTests {
    let kdbClient: KurrentDBClient = .init(settings: .localhost())
    let repository: EmployeeAccessRepository

    init() {
        self.repository = EmployeeAccessRepository(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
    }

    // happy：seed 為 資訊部門/組員 → transfer 到 財會部門/組長（皆不同）→ 兩欄位更新。
    @Test func transfer_succeeds() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, department: "資訊部門", jobTitle: "組員", repository: repository)

            _ = try await TransferDepartmentService(repository: repository).execute(input: .init(
                employeeAccessId: employeeAccessId, userId: userId, newDepartment: "財會部門", newJobTitle: "組長", operatorId: operatorId
            ))
            let aggregate = try #require(try await repository.find(byId: employeeAccessId))
            #expect(aggregate.department == "財會部門")
            #expect(aggregate.jobTitle == "組長")
        }
    }

    // guard：transfer 到與目前完全相同的 部門/職稱 → departmentUnchanged。
    @Test func transfer_unchanged_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            try await seedActiveProfile(employeeAccessId: employeeAccessId, userId: userId, operatorId: operatorId, department: "資訊部門", jobTitle: "組員", repository: repository)

            let usecase = TransferDepartmentService(repository: repository)
            let error = await #expect(throws: ContextError<EmployeeAccessError>.self) {
                let _: TransferDepartmentOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, newDepartment: "資訊部門", newJobTitle: "組員", operatorId: operatorId
                ))
            }
            #expect(error?.error == .departmentUnchanged)
        }
    }

    // infra：目標 profile 不存在 → aggregateNotFound。
    @Test func transfer_missing_profile_throws() async throws {
        try await withTestBundle(client: kdbClient) { bundle in
            let employeeAccessId = await bundle.generateAggregateRootId(for: EmployeeAccess.self)
            let userId = await bundle.generateId(for: "userId")
            let operatorId = await bundle.generateId(for: "operatorId")
            let usecase = TransferDepartmentService(repository: repository)
            let error = await #expect(throws: DDDError.self) {
                let _: TransferDepartmentOutput = try await usecase.execute(input: .init(
                    employeeAccessId: employeeAccessId, userId: userId, newDepartment: "財會部門", newJobTitle: "組長", operatorId: operatorId
                ))
            }
            #expect(error?.code == .aggregateNotFound)
        }
    }
}
