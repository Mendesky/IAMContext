import IAMContextShared

package typealias DeleteRoleApplicationServiceInput = DeleteRoleInput
package typealias DeleteRoleApplicationServiceOutput = DeleteRoleOutput

package struct DeleteRoleApplicationService: ApplicationService {
    package typealias Input = DeleteRoleApplicationServiceInput
    package typealias Output = DeleteRoleApplicationServiceOutput

    private let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }

    package func execute(input: Input) async throws -> Output {
        try await DeleteRoleService(repository: repository).execute(input: input)
    }
}
