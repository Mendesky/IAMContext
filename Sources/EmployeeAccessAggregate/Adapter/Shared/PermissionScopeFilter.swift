import IAMContextShared

/// 唯一一份 department/firm 比對邏輯（spec `docs/tasks/2026-09-03-firm-format-and-scope-check.md`
/// 驗收標準第 4 條要求：全 Adapter 只能有一處這樣的比對）。
/// `GetPermissionHoldersApplicationService` 與 `CheckScopeApplicationService` 都呼叫這裡，
/// 不得另寫第二套比對。
package enum PermissionScopeFilter {
    /// 判斷某個 userId 的 `PermissionsReadModel` 是否落在指定的 department/firm 範圍內。
    /// - Parameters:
    ///   - readModel: 該 userId 的權限讀模型。
    ///   - department: nil 表示不以部門限縮。
    ///   - firm: nil 表示不以所別限縮（統編）。
    /// - Returns: 兩個維度（若有指定）皆相符時回傳 true。
    package static func matches(readModel: PermissionsReadModel, department: String?, firm: String?) -> Bool {
        if let targetDepartment = department, readModel.department != targetDepartment {
            return false
        }
        if let targetFirm = firm, readModel.firm != targetFirm {
            return false
        }
        return true
    }
}
