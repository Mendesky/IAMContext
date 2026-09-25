import Foundation
import DDDKit
import KurrentDB
import IAMContextShared

package struct GetRolesApplicationServiceInput {
    package init() {}
}

package struct GetRolesApplicationServiceOutput {
    package let roles: [RoleSummary]

    package init(roles: [RoleSummary]) {
        self.roles = roles
    }
}

package struct GetRolesApplicationService: ApplicationService {
    package typealias Input = GetRolesApplicationServiceInput
    package typealias Output = GetRolesApplicationServiceOutput

    private let kdbClient: KurrentDBClient

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    package func execute(input: Input) async throws -> Output {
        _ = input
        let presenter = GetRolesPresenter(coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper()))
        // 只把「read model 尚無事件」（stream 不存在／projection 未部署）視為空清單；
        // 其餘錯誤（KurrentDB 不可用等）向上拋，由 ApiHandler 映射成 503（spec §4／失敗路徑）。
        do {
            guard let output = try await presenter.execute(input: .init()) else {
                return .init(roles: [])
            }
            return .init(roles: output.readModel.roles)
        } catch let error as DDDError where error.code == .eventsNotFound {
            return .init(roles: [])
        }
    }
}
