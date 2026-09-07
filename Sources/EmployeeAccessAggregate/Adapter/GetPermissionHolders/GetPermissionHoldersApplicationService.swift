import Foundation
import KurrentDB
import IAMContextShared

package struct GetPermissionHoldersApplicationServiceInput {
    package let permission: String
    /// 可選的部門過濾。nil 表示不過濾（回傳全體持有者，向後相容）。
    package let department: String?
    /// 可選的所別過濾。nil 表示不過濾（回傳全體持有者，向後相容）。
    package let firm: String?

    package init(permission: String, department: String? = nil, firm: String? = nil) {
        self.permission = permission
        self.department = department
        self.firm = firm
    }
}

package struct GetPermissionHoldersApplicationService: ApplicationService {
    package typealias Input = GetPermissionHoldersApplicationServiceInput
    package typealias Output = [String]

    private let kdbClient: KurrentDBClient

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    package func execute(input: Input) async throws -> Output {
        let presenter = GetPermissionHoldersPresenter(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
        // KDB stream `IAM_GetPermissionHolders-<permission>` 尚無任何事件（權限從未被 grant）→
        // presenter.execute 回 nil 或 DDDError.eventsNotFoundInProjector；兩者皆代表持有者為空，回 []。
        guard let output = try? await presenter.execute(input: .init(permission: input.permission)) else {
            return []
        }
        let allUserIds = output.readModel.userIds

        // 若未指定任何過濾條件，直接回傳全體持有者（向後相容）。
        guard input.department != nil || input.firm != nil else {
            return allUserIds
        }

        // 依部門和/或所別過濾：並行查各 userId 的 PermissionsReadModel，取其 department/firm 欄位比對。
        let permissionsPresenter = GetPermissionsPresenter(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
        var filtered: [String] = []
        for userId in allUserIds {
            guard let result = try? await permissionsPresenter.execute(input: .init(userId: userId)) else {
                continue
            }
            let readModel = result.readModel
            // 比對邏輯統一由 PermissionScopeFilter 提供（CheckScopeApplicationService 共用同一份，
            // 見 Adapter/Shared/PermissionScopeFilter.swift；不得另寫第二套）。
            guard PermissionScopeFilter.matches(readModel: readModel, department: input.department, firm: input.firm) else {
                continue
            }
            filtered.append(userId)
        }
        return filtered
    }
}
