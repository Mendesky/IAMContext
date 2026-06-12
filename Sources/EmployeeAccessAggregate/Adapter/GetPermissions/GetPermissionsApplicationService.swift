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

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    package func execute(input: Input) async throws -> Output {
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
