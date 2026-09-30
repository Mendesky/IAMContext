import DDDCore
import Foundation
import KurrentDB
import IAMContextShared

package struct ApiHandler: APIProtocol {

    private let kdbClient: KurrentDBClient
    private var repository: RoleRepository {
        .init(coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper()))
    }

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    private func mapToApiError(_ error: Error) -> Components.Schemas.RoleApiError? {
        if let contextError = error as? ContextError<RoleError> {
            return .init(from: contextError)
        }
        return nil
    }

    package func getRoles(_ input: Operations.getRoles.Input) async throws -> Operations.getRoles.Output {
        _ = input

        let service = GetRolesApplicationService(kdbClient: kdbClient)
        do {
            let output = try await service.execute(input: .init())
            let roles = output.roles.map {
                Components.Schemas.RoleSummary(
                    roleId: $0.roleId,
                    name: $0.name,
                    description: $0.description,
                    permissions: $0.permissions
                )
            }
            return .ok(.init(body: .json(roles)))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func createRole(_ input: Operations.createRole.Input) async throws -> Operations.createRole.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let service = CreateRoleApplicationService(repository: repository, kdbClient: kdbClient)
        do {
            let output = try await service.execute(input: .init(
                name: payload.name,
                description: payload.description,
                operatorId: input.headers.operatorId
            ))
            return .ok(.init(body: .json(.init(roleId: output.roleId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func renameRole(_ input: Operations.renameRole.Input) async throws -> Operations.renameRole.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let service = RenameRoleApplicationService(repository: repository, kdbClient: kdbClient)
        do {
            let output = try await service.execute(input: .init(
                roleId: input.path.roleId,
                newName: payload.newName,
                operatorId: input.headers.operatorId
            ))
            return .ok(.init(body: .json(.init(roleId: output.roleId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func updateRoleDescription(_ input: Operations.updateRoleDescription.Input) async throws -> Operations.updateRoleDescription.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let service = UpdateRoleDescriptionApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: .init(
                roleId: input.path.roleId,
                newDescription: payload.newDescription,
                operatorId: input.headers.operatorId
            ))
            return .ok(.init(body: .json(.init(roleId: output.roleId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func addPermissions(_ input: Operations.addPermissions.Input) async throws -> Operations.addPermissions.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let service = AddPermissionsApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: .init(
                roleId: input.path.roleId,
                permissions: payload.permissions,
                operatorId: input.headers.operatorId
            ))
            return .ok(.init(body: .json(.init(roleId: output.roleId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func removePermissions(_ input: Operations.removePermissions.Input) async throws -> Operations.removePermissions.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let service = RemovePermissionsApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: .init(
                roleId: input.path.roleId,
                permissions: payload.permissions,
                operatorId: input.headers.operatorId
            ))
            return .ok(.init(body: .json(.init(roleId: output.roleId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func deleteRole(_ input: Operations.deleteRole.Input) async throws -> Operations.deleteRole.Output {
        let service = DeleteRoleApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: .init(
                roleId: input.path.roleId,
                operatorId: input.headers.operatorId
            ))
            return .ok(.init(body: .json(.init(roleId: output.roleId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func getRolePermissions(_ input: Operations.getRolePermissions.Input) async throws -> Operations.getRolePermissions.Output {
        let service = GetRolePermissionsApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: .init(roleId: input.path.roleId))
            return .ok(.init(body: .json(output)))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }
}
