import DDDKit
import IAMContextShared

package protocol DeleteRoleUsecase: Usecase where Input == DeleteRoleInput, Output == DeleteRoleOutput {
    var repository: RoleRepository { get }
}

extension DeleteRoleUsecase {
    package func execute(input: DeleteRoleInput) async throws -> DeleteRoleOutput {
        do {
            try await repository.delete(byId: input.roleId, external: ["userId": input.operatorId])
            return .init(roleId: input.roleId, message: nil)
        } catch let error as ContextError<RoleError> {
            throw error
        } catch let error as DDDError {
            throw error
        } catch {
            throw DDDError.executeUsecaseFailed(usecase: self, input: input, userInfos: ["error": error])
        }
    }
}
