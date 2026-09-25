import DDDKit
import IAMContextShared

package protocol CreateRoleUsecase: Usecase where Input == CreateRoleInput, Output == CreateRoleOutput {
    var repository: RoleRepository { get }
}

extension CreateRoleUsecase {
    package func execute(input: CreateRoleInput) async throws -> CreateRoleOutput {
        do {
            guard !input.name.isEmpty else {
                throw ContextError<RoleError>.roleNameRequired(function: #function, message: "role name must be present and non-empty")
            }
            let role = try Role(name: input.name, description: input.description)
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
