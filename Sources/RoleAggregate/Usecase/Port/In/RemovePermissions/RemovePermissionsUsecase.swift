import DDDKit
import IAMContextShared

package protocol RemovePermissionsUsecase: Usecase where Input == RemovePermissionsInput, Output == RemovePermissionsOutput {
    var repository: RoleRepository { get }
}

extension RemovePermissionsUsecase {
    package func execute(input: RemovePermissionsInput) async throws -> RemovePermissionsOutput {
        guard let role = try await repository.find(byId: input.roleId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: Role.self, aggregateRootId: input.roleId)
        }
        do {
            try role.removePermissions(roleId: input.roleId, permissions: Set(input.permissions))
            try await repository.save(aggregateRoot: role, userId: input.operatorId)
            return .init(roleId: role.id, message: nil)
        } catch let error as ContextError<RoleError> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
    }
}
