import DDDCore
import Foundation
import KurrentDB
import IAMContextShared


package struct ApiHandler: APIProtocol {

    private let kdbClient: KurrentDBClient
    private var repository: EmployeeAccessRepository {
        return .init(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
    }

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    private func mapToApiError(_ error: Error) -> Components.Schemas.EmployeeAccessApiError? {
        if let contextError = error as? ContextError<EmployeeAccessError> {
            return .init(from: contextError)
        }
        return nil
    }

    package func grantPrivilege(_ input: Operations.grantPrivilege.Input) async throws -> Operations.grantPrivilege.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let employeeAccessId = input.path.employeeAccessId
        let operatorId = input.headers.operatorId
        let asInput = GrantPrivilegeApplicationServiceInput(
            employeeAccessId: employeeAccessId,
            userId: payload.userId,
            permissions: payload.permissions,
            operatorId: operatorId
        )

        let service = GrantPrivilegeApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: asInput)
            return .ok(.init(body: .json(.init(employeeAccessId: output.employeeAccessId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func revokePrivilege(_ input: Operations.revokePrivilege.Input) async throws -> Operations.revokePrivilege.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let employeeAccessId = input.path.employeeAccessId
        let operatorId = input.headers.operatorId
        let asInput = RevokePrivilegeApplicationServiceInput(
            employeeAccessId: employeeAccessId,
            userId: payload.userId,
            permissions: payload.permissions,
            operatorId: operatorId
        )

        let service = RevokePrivilegeApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: asInput)
            return .ok(.init(body: .json(.init(employeeAccessId: output.employeeAccessId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func assignRoles(_ input: Operations.assignRoles.Input) async throws -> Operations.assignRoles.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let employeeAccessId = input.path.employeeAccessId
        let operatorId = input.headers.operatorId
        let asInput = AssignRolesApplicationServiceInput(
            employeeAccessId: employeeAccessId,
            userId: payload.userId,
            roles: payload.roles,
            operatorId: operatorId
        )

        let service = AssignRolesApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: asInput)
            return .ok(.init(body: .json(.init(employeeAccessId: output.employeeAccessId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func revokeRoles(_ input: Operations.revokeRoles.Input) async throws -> Operations.revokeRoles.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let employeeAccessId = input.path.employeeAccessId
        let operatorId = input.headers.operatorId
        let asInput = RevokeRolesApplicationServiceInput(
            employeeAccessId: employeeAccessId,
            userId: payload.userId,
            roles: payload.roles,
            operatorId: operatorId
        )

        let service = RevokeRolesApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: asInput)
            return .ok(.init(body: .json(.init(employeeAccessId: output.employeeAccessId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func promoteUser(_ input: Operations.promoteUser.Input) async throws -> Operations.promoteUser.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let employeeAccessId = input.path.employeeAccessId
        let operatorId = input.headers.operatorId
        let asInput = PromoteUserApplicationServiceInput(
            employeeAccessId: employeeAccessId,
            userId: payload.userId,
            newJobTitle: payload.newJobTitle,
            oldJobTitle: payload.oldJobTitle,
            operatorId: operatorId
        )

        let service = PromoteUserApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: asInput)
            return .ok(.init(body: .json(.init(employeeAccessId: output.employeeAccessId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func transferDepartment(_ input: Operations.transferDepartment.Input) async throws -> Operations.transferDepartment.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let employeeAccessId = input.path.employeeAccessId
        let operatorId = input.headers.operatorId
        let asInput = TransferDepartmentApplicationServiceInput(
            employeeAccessId: employeeAccessId,
            userId: payload.userId,
            newDepartment: payload.newDepartment,
            newJobTitle: payload.newJobTitle,
            operatorId: operatorId,
            newFirm: payload.newFirm
        )

        let service = TransferDepartmentApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: asInput)
            return .ok(.init(body: .json(.init(employeeAccessId: output.employeeAccessId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func createUserAccessProfile(_ input: Operations.createUserAccessProfile.Input) async throws -> Operations.createUserAccessProfile.Output {
        guard case let .json(payload) = input.body else {
            return .unprocessableContent(.init(body: .json(.init(error: .invalidPayload))))
        }
        let employeeAccessId = input.path.employeeAccessId
        let operatorId = input.headers.operatorId
        let asInput = CreateUserAccessProfileApplicationServiceInput(
            employeeAccessId: employeeAccessId,
            userId: payload.userId,
            department: payload.department,
            jobTitle: payload.jobTitle,
            operatorId: operatorId,
            firm: payload.firm
        )

        let service = CreateUserAccessProfileApplicationService(repository: repository)
        do {
            let output = try await service.execute(input: asInput)
            return .ok(.init(body: .json(.init(employeeAccessId: output.employeeAccessId))))
        } catch let error as DDDError where error.code == .aggregateNotFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func getPermissions(_ input: Operations.getPermissions.Input) async throws -> Operations.getPermissions.Output {
        let userId = input.path.userId

        let service = GetPermissionsApplicationService(kdbClient: kdbClient)
        let asInput = GetPermissionsApplicationServiceInput(
            userId: userId
        )
        do {
            let output = try await service.execute(input: asInput)
            return .ok(.init(body: .json(output)))
        } catch let error as ContextError<EmployeeAccessQueryError> where error.error == .notFound {
            return .notFound(.init(body: .json(.init(error: .aggregateNotFound))))
        } catch {
            if let apiError = mapToApiError(error) {
                return .unprocessableContent(.init(body: .json(.init(error: apiError))))
            }
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

    package func getPermissionHolders(_ input: Operations.getPermissionHolders.Input) async throws -> Operations.getPermissionHolders.Output {
        let permission = input.query.permission
        let department = input.query.department
        let firm = input.query.firm

        let service = GetPermissionHoldersApplicationService(kdbClient: kdbClient)
        do {
            let output = try await service.execute(input: .init(permission: permission, department: department, firm: firm))
            return .ok(.init(body: .json(output)))
        } catch {
            return .serviceUnavailable(.init(body: .json(.init(error: .serviceUnavailable))))
        }
    }

}
