import IAMContextShared

package typealias UpdateRoleDescriptionApplicationServiceInput = UpdateRoleDescriptionInput
package typealias UpdateRoleDescriptionApplicationServiceOutput = UpdateRoleDescriptionOutput

package struct UpdateRoleDescriptionApplicationService: ApplicationService {
    package typealias Input = UpdateRoleDescriptionApplicationServiceInput
    package typealias Output = UpdateRoleDescriptionApplicationServiceOutput

    private let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }

    package func execute(input: Input) async throws -> Output {
        try await UpdateRoleDescriptionService(repository: repository).execute(input: input)
    }
}
