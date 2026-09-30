import IAMContextShared

package typealias AddPermissionsApplicationServiceInput = AddPermissionsInput
package typealias AddPermissionsApplicationServiceOutput = AddPermissionsOutput

package struct AddPermissionsApplicationService: ApplicationService {
    package typealias Input = AddPermissionsApplicationServiceInput
    package typealias Output = AddPermissionsApplicationServiceOutput

    private let repository: RoleRepository

    package init(repository: RoleRepository) {
        self.repository = repository
    }

    package func execute(input: Input) async throws -> Output {
        try await AddPermissionsService(repository: repository).execute(input: input)
    }
}
