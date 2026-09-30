import DDDKit
import IAMContextShared

package protocol RenameRoleUsecase: Usecase where Input == RenameRoleInput, Output == RenameRoleOutput {
    var repository: RoleRepository { get }
}

extension RenameRoleUsecase {
    package func execute(input: RenameRoleInput) async throws -> RenameRoleOutput {
        guard let role = try await repository.find(byId: input.roleId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: Role.self, aggregateRootId: input.roleId)
        }
        do {
            try role.rename(roleId: input.roleId, newName: input.newName)
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
