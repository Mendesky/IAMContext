import DDDKit
import IAMContextShared

package protocol GrantPrivilegeUsecase: Usecase where Input == GrantPrivilegeInput, Output == GrantPrivilegeOutput {
    var repository: EmployeeAccessRepository { get }
    var effectivePermissionsReader: EffectivePermissionsReader { get }
    /// 哪些權限是範圍化的、允許哪些範圍種類（2026-11-25 設計文件 D7、D10）。
    var grantScopePolicy: GrantScopePolicy { get }
}

extension GrantPrivilegeUsecase {
    package func execute(input: GrantPrivilegeInput) async throws -> GrantPrivilegeOutput {
        guard let employeeAccess = try await repository.find(byId: input.employeeAccessId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: EmployeeAccess.self, aggregateRootId: input.employeeAccessId)
        }
        do {
            let alreadyDirect = Set(input.permissions).intersection(employeeAccess.permissions ?? [])
            var lapsedDirectGrants: Set<String> = []
            if !alreadyDirect.isEmpty {
                let effective = try await effectivePermissionsReader.effectivePermissions(employeeAccessId: input.employeeAccessId)
                lapsedDirectGrants = alreadyDirect.subtracting(effective)
            }
            try employeeAccess.grantPrivilege(
                employeeAccessId: input.employeeAccessId,
                userId: input.userId,
                permissions: input.permissions,
                grantScopes: input.grantScopes,
                grantScopeRules: grantScopePolicy.rules(for: input.permissions),
                lapsedDirectGrants: lapsedDirectGrants
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
