import Foundation
import DDDKit
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
    /// 角色定義出埠（階段二 role-permission-composition §g）：反查「含此權限的角色」，把角色持有者併進結果。
    private let roleDirectory: RoleDirectory

    package init(kdbClient: KurrentDBClient, roleDirectory: RoleDirectory) {
        self.kdbClient = kdbClient
        self.roleDirectory = roleDirectory
    }

    package func execute(input: Input) async throws -> Output {
        // 1. 直接持有者。KDB stream `IAM_GetPermissionHolders-<permission>` 尚無任何事件（權限從未被直接 grant）
        //    → presenter.execute 回 nil 或 DDDError(.eventsNotFound)；兩者皆代表「零位直接持有者」。
        //    階段二把原本的 early return 拿掉：直接持有者為空仍要往下跑角色展開，否則「只經由角色持有」的人永遠查不到。
        //    與階段一 GetRoles／GetRoleHolders 同一窄 catch：其餘錯誤（KurrentDB 不可用等）向上拋，由 ApiHandler 映射成 503。
        let presenter = GetPermissionHoldersPresenter(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )
        let directHolders: [String]
        do {
            directHolders = try await presenter.execute(input: .init(permission: input.permission))?.readModel.userIds ?? []
        } catch let error as DDDError where error.code == .eventsNotFound {
            directHolders = []
        }

        // 2. 含此權限的角色（GetRoles 目錄，最終一致）→ 3. 每個角色的持有者（GetRoleHolders projection，同 target）。
        let roleIds = try await roleDirectory.rolesContaining(permission: input.permission)
        var roleHolderIds: Set<String> = []
        if !roleIds.isEmpty {
            let roleHoldersService = GetRoleHoldersApplicationService(kdbClient: kdbClient)
            for roleId in roleIds.sorted() {
                roleHolderIds.formUnion(try await roleHoldersService.execute(input: .init(role: roleId)))
            }
        }

        // 4. 聯集：直接持有者保留原順序，只經由角色持有的人排序後接在後面（去重、順序可重現）。
        let allUserIds = directHolders + roleHolderIds.subtracting(directHolders).sorted()

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
