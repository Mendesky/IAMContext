import Foundation
import KurrentDB
import IAMContextShared

/// 授權範圍判斷（spec `docs/tasks/2026-09-03-firm-format-and-scope-check.md` §2）。
/// 語意：回傳 `userIds` 之中，屬於指定 department/firm 範圍者（交集）。
/// - `department`/`firm` 皆為 nil → 回傳所有存在於 IAM 的 userId（不依 EmployeeStatus 過濾，
///   與既有 `getPermissionHolders` 行為一致——`PermissionsReadModel` 本身未投影 status 欄位）。
/// - 查不到 `PermissionsReadModel` 的 userId：靜默排除，不拋錯。
/// - 只回傳判斷結果（`inScope`），不回傳 department/firm 屬性——避免與 StaffContext 名冊查詢功能重疊。
package struct CheckScopeApplicationServiceInput {
    /// 要判斷的對象，可為空（回傳空陣列，不視為錯誤）。
    package let userIds: [String]
    /// 所別（統編）過濾。nil = 不以所別限縮。
    package let firm: String?
    /// 部門過濾。nil = 不以部門限縮。
    package let department: String?

    package init(userIds: [String], firm: String? = nil, department: String? = nil) {
        self.userIds = userIds
        self.firm = firm
        self.department = department
    }
}

package struct CheckScopeApplicationServiceOutput {
    /// userIds 之中屬於該範圍者，去重，順序不保證。
    package let inScope: [String]
}

package struct CheckScopeApplicationService: ApplicationService {
    package typealias Input = CheckScopeApplicationServiceInput
    package typealias Output = CheckScopeApplicationServiceOutput

    private let kdbClient: KurrentDBClient

    package init(kdbClient: KurrentDBClient) {
        self.kdbClient = kdbClient
    }

    package func execute(input: Input) async throws -> Output {
        // 空輸入 → 直接回空陣列，不查 KDB（spec 失敗路徑：空輸入回 200 { inScope: [] }）。
        guard !input.userIds.isEmpty else {
            return .init(inScope: [])
        }

        let permissionsPresenter = GetPermissionsPresenter(
            coordinator: .init(client: kdbClient, eventMapper: EmployeeAccessAggregateEventMapper())
        )

        var seen = Set<String>()
        var inScope: [String] = []
        for userId in input.userIds {
            // 去重：同一 userId 只判斷一次、只出現一次。
            guard !seen.contains(userId) else { continue }
            seen.insert(userId)

            // 查不到讀模型（IAM 無此人）→ 靜默排除，不拋錯（spec §2 / 失敗路徑表）。
            guard let result = try? await permissionsPresenter.execute(input: .init(userId: userId)) else {
                continue
            }
            let readModel = result.readModel
            guard PermissionScopeFilter.matches(readModel: readModel, department: input.department, firm: input.firm) else {
                continue
            }
            inScope.append(userId)
        }
        return .init(inScope: inScope)
    }
}
