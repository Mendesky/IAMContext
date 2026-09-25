import DDDKit
import Foundation
import KurrentDB
import IAMContextShared
import protocol EmployeeAccessAggregate.RoleDirectory

/// `RoleDirectory` 的生產實作（docs/tasks/role-permission-composition.md §b）。
///
/// - `resolve`：對每個 roleId rehydrate Role aggregate（強一致）；`find(byId:)` 對不存在／已刪除回 nil → 略過。
/// - `rolesContaining`：折疊 `IAM_GetRoles-all`（GetRoles projection，最終一致）。
///
/// 只持有 `KurrentDBClient`（Sendable），repository 與 presenter 每次呼叫時建立——
/// 與 ApiHandler 的 `repository` computed property 同一模式，避免把非 Sendable 的
/// `KurrentStorageCoordinator` 存進要跨 actor（PermissionsService）持有的值。
package struct RoleAggregateDirectory: RoleDirectory {
    private let kdbClient: KurrentDBClient

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    private var repository: RoleRepository {
        .init(coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper()))
    }

    package func resolve(roleIds: Set<String>) async throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let repository = self.repository
        for roleId in roleIds {
            // 不存在／已刪除（repository.find 預設 hiddingDeleted）→ nil → 不進字典。
            guard let role = try await repository.find(byId: roleId) else { continue }
            result[roleId] = role.permissions ?? []
        }
        return result
    }

    package func rolesContaining(permission: String) async throws -> Set<String> {
        let presenter = GetRolesPresenter(coordinator: .init(client: kdbClient, eventMapper: RoleAggregateEventMapper()))
        // 與階段一 GetRolesApplicationService 同一窄 catch：只把「read model 尚無事件」
        //（stream 不存在／projection 未部署）視為空集合；其餘錯誤（KurrentDB 不可用等）向上拋。
        do {
            guard let output = try await presenter.execute(input: .init()) else { return [] }
            return Set(output.readModel.roles.filter { $0.permissions.contains(permission) }.map(\.roleId))
        } catch let error as DDDError where error.code == .eventsNotFound {
            return []
        }
    }
}
