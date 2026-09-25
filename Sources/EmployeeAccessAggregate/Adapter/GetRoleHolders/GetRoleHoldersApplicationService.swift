import Foundation
import DDDKit
import KurrentDB
import IAMContextShared

package struct GetRoleHoldersApplicationServiceInput {
    package let role: String

    package init(role: String) {
        self.role = role
    }
}

package struct GetRoleHoldersApplicationService: ApplicationService {
    package typealias Input = GetRoleHoldersApplicationServiceInput
    package typealias Output = [String]

    private let kdbClient: KurrentDBClient

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    package func execute(input: Input) async throws -> Output {
        let presenter = GetRoleHoldersPresenter(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
        // 只把「read model 尚無事件」（無人持有／projection 未部署）視為空清單；
        // 其餘錯誤（KurrentDB 不可用等）向上拋，由 ApiHandler 映射成 503（spec §4／失敗路徑）。
        do {
            guard let output = try await presenter.execute(input: .init(role: input.role)) else {
                return []
            }
            return output.readModel.userIds
        } catch let error as DDDError where error.code == .eventsNotFound {
            return []
        }
    }
}
