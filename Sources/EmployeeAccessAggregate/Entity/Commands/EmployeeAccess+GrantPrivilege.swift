import DDDKit
import Foundation
import IAMContextShared
extension EmployeeAccess {
    /// - Parameters:
    ///   - grantScopes: 範圍化權限的授權範圍（權限 → 範圍清單）。
    ///   - grantScopeRules: 這次授予的權限裡，範圍化的權限 → 範圍規則（類型、允許的種類；由 usecase 從 `GrantScopePolicy` 查好傳進來）。
    ///     範圍化的權限一定要帶範圍；不是範圍化的權限不能帶（`GrantScopeRules.validatedGrant`）。
    package func grantPrivilege(
        employeeAccessId: String,
        userId: String,
        permissions: [String],
        grantScopes: [String: [GrantScope]] = [:],
        grantScopeRules: [String: GrantScopeRule],
        lapsedDirectGrants: Set<String> = []
    ) throws {
        // PRECONDITION: permissions cannot be both directly granted and still effective.
        let direct = self.permissions ?? []
        guard !permissions.contains(where: { direct.contains($0) && !lapsedDirectGrants.contains($0) }) else {
            throw ContextError<EmployeeAccessError>.permissionAlreadyExists(function: #function, message: "permission already granted to user")
        }
        // IDENTITY GUARD (code review 2026-06-12): aggregate 由 employeeAccessId 載入，event 的 userId 必須是這個
        // profile 真正的 userId（self.userId），不可信任請求帶來的 userId。否則打錯/填別人 userId 會把權限事件灌進別人
        // 的身分，污染 GetPermissions 投影（以 userId 分區）與任何下游稽核。self.userId 建檔後不可變，故一律比對相等。
        guard userId == self.userId else {
            throw ContextError<EmployeeAccessError>.userIdMismatch(function: #function, message: "request userId does not match this profile's userId")
        }
        // 授權範圍（2026-11-25 設計文件 D7、D10）：範圍化的權限一定要帶合法的範圍，不是範圍化的權限不能帶。
        let validatedScopes = try GrantScopeRules.validatedGrant(permissions: permissions, grantScopes: grantScopes, rules: grantScopeRules)
        let event = PrivilegeGranted(
            employeeAccessId: self.id,
            userId: userId,
            permissions: permissions,
            grantScopes: validatedScopes.isEmpty ? nil : validatedScopes,
            occurred: .now
        )
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches PrivilegeGranted.
    // ⚠️ this is the file where state actually changes during replay; do NOT mutate in grantPrivilege().
    package func when(event: PrivilegeGranted) throws {
        // PrivilegeGranted state transition is not strict-safe (empty payload / collection / type-mismatch / new-old rename / nested).
        // domain-fill: 聯集加入 event.permissions（nil 視為空集合）
        self.permissions = (self.permissions ?? []).union(event.permissions)
        // 授權範圍：這次授予的權限，有範圍的記下（覆蓋），沒有的清掉（舊事件、不是範圍化的權限都沒有）。
        for permission in event.permissions {
            self.grantScopes[permission] = event.grantScopes?[permission]
        }
    }
}
