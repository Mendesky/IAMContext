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
    /// 角色定義出埠：提供反查候選人與逐人重播所需的角色歷史。
    private let roleDirectory: RoleDirectory

    package init(kdbClient: KurrentDBClient, roleDirectory: RoleDirectory) {
        self.kdbClient = kdbClient
        self.roleDirectory = roleDirectory
    }

    package func execute(input: Input) async throws -> Output {
        let timeline = PermissionTimelineService(kdbClient: kdbClient, roleDirectory: roleDirectory)

        // 1. 候選人（超集合）：曾被直接授予者 ∪ 曾持有「任何時候含過該權限的角色」者。
        let candidates = try await timeline.candidateUserIds(permission: input.permission)

        // 2. 每位候選人重播（與 getPermissions 同一套規則）；只留下有效權限含此權限者。
        //    被個別撤銷、或角色已移除／刪除該權限的人在這裡被濾掉。
        let effectiveByUser = try await timeline.effectivePermissions(userIds: candidates)
        let holders = candidates.filter { effectiveByUser[$0]?.contains(input.permission) == true }

        // 若未指定任何過濾條件，直接回傳全體持有者（向後相容）。
        guard input.department != nil || input.firm != nil else {
            return holders
        }

        // 依部門和/或所別過濾：逐一查各 userId 的 PermissionsReadModel，取其 department/firm 欄位比對。
        let permissionsPresenter = GetPermissionsPresenter(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
        var filtered: [String] = []
        for userId in holders {
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
