import DDDKit
import IAMContextShared

package protocol UpdateRoleDescriptionUsecase: Usecase where Input == UpdateRoleDescriptionInput, Output == UpdateRoleDescriptionOutput {
    var repository: RoleRepository { get }
}

extension UpdateRoleDescriptionUsecase {
    package func execute(input: UpdateRoleDescriptionInput) async throws -> UpdateRoleDescriptionOutput {
        guard let role = try await repository.find(byId: input.roleId) else {
            throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: Role.self, aggregateRootId: input.roleId)
        }
        do {
            try role.updateDescription(roleId: input.roleId, newDescription: input.newDescription)
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
