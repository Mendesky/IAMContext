import Foundation
import KurrentDB
import IAMContextShared

package struct GetPermissionsApplicationServiceInput {
    package let userId: String

    package init(userId: String) {
        self.userId = userId
    }
}

package struct GetPermissionsApplicationService: ApplicationService {
    package typealias Input = GetPermissionsApplicationServiceInput
    package typealias Output = [String]

    private let kdbClient: KurrentDBClient

    /// When non-nil, the service bypasses the per-user read-model lookup and returns this
    /// fixed set instead.  Used by IAMContextServer to implement IAM_DEBUG_FULL_PERMISSIONS:
    /// the server resolves PermissionCatalog.allRawValues (from IAMPermissionCatalog target)
    /// and passes it here so this target stays free of that dependency.
    package let debugOverridePermissions: [String]?

    package init(kdbClient: KurrentDBClient, debugOverridePermissions: [String]? = nil) {
        self.kdbClient = kdbClient
        self.debugOverridePermissions = debugOverridePermissions
    }

    package func execute(input: Input) async throws -> Output {
        // IAM_DEBUG_FULL_PERMISSIONS=1 — skip per-user lookup, return the injected catalog.
        // getPermissionHolders is intentionally not affected.
        if let overrides = debugOverridePermissions {
            return overrides
        }

        // /presenter-fill: 透過 GetPermissionsPresenter（projector）抓 read model，map readModel.permissions → Output。
        let presenter = GetPermissionsPresenter(coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper()))
        guard let readModel = try await presenter.execute(input: .init(userId: input.userId))?.readModel else {
            throw ContextError<EmployeeAccessQueryError>(
                error: .notFound,
                in: .struct(GetPermissionsApplicationService.self, function: #function),
                message: "read model not found for \(input.userId)"
            )
        }
        return readModel.permissions ?? []
    }
}
