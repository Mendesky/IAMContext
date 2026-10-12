import DDDKit
import IAMContextShared

package protocol GrantPrivilegeUsecase: Usecase where Input == GrantPrivilegeInput, Output == GrantPrivilegeOutput {
    var repository: EmployeeAccessRepository { get }
    var effectivePermissionsReader: EffectivePermissionsReader { get }
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
            try employeeAccess.grantPrivilege(employeeAccessId: input.employeeAccessId, userId: input.userId, permissions: input.permissions, lapsedDirectGrants: lapsedDirectGrants)
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
