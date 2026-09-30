import IAMContextShared

package typealias RemovePermissionsApplicationServiceInput = RemovePermissionsInput
package typealias RemovePermissionsApplicationServiceOutput = RemovePermissionsOutput

package struct RemovePermissionsApplicationService: ApplicationService {
    package typealias Input = RemovePermissionsApplicationServiceInput
    package typealias Output = RemovePermissionsApplicationServiceOutput

    private let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }

    package func execute(input: Input) async throws -> Output {
        try await RemovePermissionsService(repository: repository).execute(input: input)
    }
}
