import EmployeeAccessAggregate

// 整合測試共用 seed helper：透過 create Service 鋪一個 active profile（會持久化到 KDB）。
// 注意：create convenience init 以「空權限」起始（roles 空、status .Active）；需要權限的測試請自行 grant。
// 非 create UC 的測試起點都用它。ids 由各 test 的 bundle.generateAggregateRootId / generateId 鑄。
@discardableResult
func seedActiveProfile(
    employeeAccessId: String,
    userId: String,
    operatorId: String,
    department: String = "資訊部門",
    jobTitle: String = "組員",
    repository: EmployeeAccessRepository
) async throws -> CreateUserAccessProfileOutput {
    try await CreateUserAccessProfileService(repository: repository).execute(input: .init(
        employeeAccessId: employeeAccessId,
        userId: userId,
        department: department,
        jobTitle: jobTitle,
        operatorId: operatorId
    ))
}
