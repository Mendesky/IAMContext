import Foundation
import KurrentDB
import IAMContextShared

/// 持有者判斷（`POST /employee-access/permission-holder-check`）。
/// 語意：回傳 `userIds` 之中，目前持有 `permission` 者——等同 `getPermissionHolders(permission)` 限縮在這批人。
/// - 判斷規則與 `getPermissionHolders` 相同：每人以 `PermissionTimelineService` 重播權限時間軸，
///   被個別撤銷、或角色已移除／刪除該權限的人不算持有者。
/// - 與 `getPermissionHolders` 的差別只在範圍：不經候選人發現、不掃「曾被授予過」的全體，只重播給定的人
///   （呼叫端 OpportunityContext 只需判斷一組 3–5 人的名單或單一操作者，全體重播一次要數秒）。
///   因此也不受 `getPermissionHolders` 候選人發現的盲區影響（只靠建檔事件初始權限／角色持有者，
///   見 `docs/tasks/permission-timeline-composition.md` 已知限制 #3）——這類人在這裡會判為持有者，與 `getPermissions` 一致。
/// - 不受 `IAM_DEBUG_FULL_PERMISSIONS` 影響（與 `getPermissionHolders` 相同，見 `IAMContextServer/DebugConfig.swift`）：
///   本服務不接 debug 覆寫。
/// - 查不到的 userId（IAM 無此人）：靜默排除，不拋錯。
/// - 讀取或重播失敗：整批拋錯（fail-closed，HTTP 層回 503），不回部分結果。
package struct CheckPermissionHoldersApplicationServiceInput {
    /// 要判斷的 permission rawValue。空白檢查在 HTTP 層（422），這裡不重複驗證。
    package let permission: String
    /// 要判斷的對象，可為空（回傳空陣列，不視為錯誤）。
    package let userIds: [String]

    package init(permission: String, userIds: [String]) {
        self.permission = permission
        self.userIds = userIds
    }
}

package struct CheckPermissionHoldersApplicationServiceOutput {
    /// userIds 之中目前持有該 permission 者，去重，順序不保證（實作上依輸入首次出現的順序）。
    package let holders: [String]
}

package struct CheckPermissionHoldersApplicationService: ApplicationService {
    package typealias Input = CheckPermissionHoldersApplicationServiceInput
    package typealias Output = CheckPermissionHoldersApplicationServiceOutput

    /// 同時讀取員工 stream 的上限。呼叫端常態是 1 人或 3–5 人；上限只是防止一次送大量 userId 時同時開太多讀取。
    static let maxConcurrentReads = 8

    private let kdbClient: KurrentDBClient
    /// 角色定義出埠：重播時讀取員工持有過的角色歷史（與 getPermissionHolders 同一個實例）。
    private let roleDirectory: RoleDirectory

    package init(kdbClient: KurrentDBClient, roleDirectory: RoleDirectory) {
        self.kdbClient = kdbClient
        self.roleDirectory = roleDirectory
    }

    package func execute(input: Input) async throws -> Output {
        // 空輸入 → 直接回空陣列，不查 KDB。
        guard !input.userIds.isEmpty else {
            return .init(holders: [])
        }

        // 去重：同一 userId 只判斷一次、只出現一次（保留首次出現的順序）。
        var seen: Set<String> = []
        let uniqueUserIds = input.userIds.filter { seen.insert($0).inserted }

        // 只重播給定的人（與 getPermissions／getPermissionHolders 同一套規則）；查無此人的不在結果字典裡 → 自然排除。
        let timeline = PermissionTimelineService(kdbClient: kdbClient, roleDirectory: roleDirectory)
        let effectiveByUser = try await timeline.effectivePermissionsConcurrently(
            userIds: uniqueUserIds,
            maxConcurrentReads: Self.maxConcurrentReads
        )
        let holders = uniqueUserIds.filter { effectiveByUser[$0]?.contains(input.permission) == true }
        return .init(holders: holders)
    }
}
