import DDDKit
import IAMContextShared
import IAMPermissionCatalog

package protocol AddPermissionsUsecase: Usecase where Input == AddPermissionsInput, Output == AddPermissionsOutput {
    var repository: RoleRepository { get }
}

extension AddPermissionsUsecase {
    package func execute(input: AddPermissionsInput) async throws -> AddPermissionsOutput {
        do {
            guard input.permissions.allSatisfy({ PermissionCatalog.allRawValues.contains($0) }) else {
                throw ContextError<RoleError>.invalidPermission(function: #function, message: "permissions must all exist in PermissionCatalog")
            }
            guard let role = try await repository.find(byId: input.roleId) else {
                throw DDDError.aggregateNotFound(usecase: self, aggregateRootType: Role.self, aggregateRootId: input.roleId)
            }
            try role.addPermissions(roleId: input.roleId, permissions: Set(input.permissions))
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
