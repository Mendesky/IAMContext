import DDDKit
import Foundation
import IAMContextShared
extension EmployeeAccess {
    /// 改一個範圍化權限的授權範圍（整組換掉；2026-11-25 設計文件 D12，2026-11-26 改成自己的事件型別）。
    ///
    /// 發 `PrivilegeScopeChanged`：如實記下「誰、什麼時候、把範圍改成什麼」，不用「撤銷＋授予」
    /// （那會記一筆實際沒發生的撤銷，投影逐筆連結時中間也可能查不到權限）。
    /// 轉換時幫「權限標成範圍化之前就持有、還沒有範圍」的人補範圍，也用這個指令。
    ///
    /// - Parameters:
    ///   - rule: 這個權限的範圍規則（類型、允許的種類）；nil＝不是範圍化的權限（由 usecase 從 `GrantScopePolicy` 查好傳進來）。
    ///   - isEffective: 這個權限目前是否有效（由 usecase 用時間軸重播查好傳進來）。直接授予後可能因為撤銷含它的角色而失效
    ///     （撤銷不論來源），那時改範圍等於重新授權，所以拒絕，要用授權。
    package func changeGrantScope(
        employeeAccessId: String,
        userId: String,
        permission: String,
        grantScopes: [GrantScope],
        rule: GrantScopeRule?,
        isEffective: Bool
    ) throws {
        // IDENTITY GUARD：同 grantPrivilege，event 的 userId 必須等於本 profile 的 self.userId。
        guard userId == self.userId else {
            throw ContextError<EmployeeAccessError>.userIdMismatch(function: #function, message: "request userId does not match this profile's userId")
        }
        // 只能改「直接持有、而且目前有效」的權限的範圍（範圍化的權限只能直接授予，不會從角色來）。
        guard (self.permissions ?? []).contains(permission), isEffective else {
            throw ContextError<EmployeeAccessError>.permissionNotExist(function: #function, message: "permission \(permission) is not directly granted to user or no longer effective")
        }
        guard let rule else {
            throw ContextError<EmployeeAccessError>.grantScopeNotApplicable(function: #function, message: "permission \(permission) does not take a grant scope")
        }
        let validated = try GrantScopeRules.validated(grantScopes, rule: rule, permission: permission)
        guard validated != (self.grantScopes[permission] ?? []) else {
            throw ContextError<EmployeeAccessError>.grantScopeUnchanged(function: #function, message: "grant scope of \(permission) is unchanged")
        }
        try self.apply(event: PrivilegeScopeChanged(
            employeeAccessId: self.id,
            userId: userId,
            permission: permission,
            grantScopes: validated,
            occurred: .now
        ))
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches PrivilegeScopeChanged.
    // ⚠️ this is the file where state actually changes during replay; do NOT mutate in changeGrantScope().
    package func when(event: PrivilegeScopeChanged) throws {
        self.grantScopes[event.permission] = event.grantScopes
    }
}
