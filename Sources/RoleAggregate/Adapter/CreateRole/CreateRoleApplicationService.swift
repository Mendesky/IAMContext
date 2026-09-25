import Foundation
import KurrentDB
import IAMContextShared

package typealias CreateRoleApplicationServiceInput = CreateRoleInput
package typealias CreateRoleApplicationServiceOutput = CreateRoleOutput

package struct CreateRoleApplicationService: ApplicationService {
    package typealias Input = CreateRoleApplicationServiceInput
    package typealias Output = CreateRoleApplicationServiceOutput

    private let repository: RoleRepository
    private let kdbClient: KurrentDBClient

    package init(repository: RoleRepository, kdbClient: KurrentDBClient) {
        self.repository = repository
        self.kdbClient = kdbClient
    }

    package func execute(input: Input) async throws -> Output {
        try await ensureRoleNameIsUnique(name: input.name)
        return try await CreateRoleService(repository: repository).execute(input: input)
    }

    private func ensureRoleNameIsUnique(name: String) async throws {
        let presenter = GetRolesPresenter(coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper()))
        guard let output = try? await presenter.execute(input: .init()) else {
            return
        }
        if output.readModel.roles.contains(where: { $0.name == name }) {
            throw ContextError<RoleError>.roleNameDuplicated(function: #function, message: "role name already exists")
        }
    }
}
