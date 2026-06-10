import DDDKit

package struct RevokeRolesOutput: UseCaseOutput {
    package let id: String?
    package let message: String?

    package init(id: String?, message: String? = nil) {
        self.id = id
        self.message = message
    }
}
