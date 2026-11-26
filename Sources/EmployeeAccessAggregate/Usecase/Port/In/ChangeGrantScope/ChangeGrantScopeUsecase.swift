import DDDKit
import IAMContextShared

/// 改一個範圍化權限的授權範圍（2026-11-25 設計文件 D12）。檢查在指令（`EmployeeAccess.changeGrantScope`），
/// usecase 只負責從 `GrantScopePolicy` 查出這個權限允許的範圍種類傳進去。
package protocol ChangeGrantScopeUsecase: Usecase where Input == ChangeGrantScopeInput, Output == ChangeGrantScopeOutput {
    var repository: EmployeeAccessRepository { get }
    var grantScopePolicy: GrantScopePolicy { get }
}

extension ChangeGrantScopeUsecase {
    package func execute(input: ChangeGrantScopeInput) async throws -> ChangeGrantScopeOutput {
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            try employeeAccess.changeGrantScope(
                employeeAccessId: input.employeeAccessId,
                userId: input.userId,
                permission: input.permission,
                grantScopes: input.grantScopes,
                allowedKinds: grantScopePolicy.allowedKinds(for: [input.permission])[input.permission]
            )
            try await repository.save(aggregateRoot: employeeAccess, userId: input.operatorId)
            return .init(id: employeeAccess.id, message: nil)
        } catch let error as ContextError<EmployeeAccessError> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
    }
}
