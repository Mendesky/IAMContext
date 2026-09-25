import Foundation
import KurrentDB
import IAMContextShared

package typealias RenameRoleApplicationServiceInput = RenameRoleInput
package typealias RenameRoleApplicationServiceOutput = RenameRoleOutput

package struct RenameRoleApplicationService: ApplicationService {
    package typealias Input = RenameRoleApplicationServiceInput
    package typealias Output = RenameRoleApplicationServiceOutput

    private let repository: RoleRepository
    private let kdbClient: KurrentDBClient

    package init(repository: RoleRepository, kdbClient: KurrentDBClient) {
        self.repository = repository
        self.kdbClient = kdbClient
    }

    package func execute(input: Input) async throws -> Output {
        try await ensureRoleNameIsUnique(name: input.newName, excludingRoleId: input.roleId)
        return try await RenameRoleService(repository: repository).execute(input: input)
    }

    private func ensureRoleNameIsUnique(name: String, excludingRoleId roleId: String) async throws {
        let presenter = GetRolesPresenter(coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper()))
        guard let output = try? await presenter.execute(input: .init()) else {
            return
        }
        if output.readModel.roles.contains(where: { $0.roleId != roleId && $0.name == name }) {
            throw ContextError<RoleError>.roleNameDuplicated(function: #function, message: "role name already exists")
        }
    }
}
