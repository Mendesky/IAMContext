import DDDKit
import Foundation
import IAMContextShared
extension EmployeeAccess {
    /// 改一個範圍化權限的授權範圍（2026-11-25 設計文件 D12）。
    ///
    /// 已持有的權限不能再授予一次（`permissionAlreadyExists`），所以改範圍是另一個指令；但**不新增事件型別**：
    /// 同一次寫入發 `PrivilegeRevoked` ＋ 帶新範圍的 `PrivilegeGranted`。舊版 IAM 讀得懂這兩種事件
    /// （只是看不到範圍），所以寫過改範圍之後仍可退版；投影也不用改。
    /// 轉換時幫「已持有、還沒有範圍」的人補範圍，也用這個指令（現在的範圍是空的，一定不會跟新範圍一樣）。
    ///
    /// - Parameter allowedKinds: 這個權限允許的範圍種類；nil＝不是範圍化的權限（由 usecase 從 `GrantScopePolicy` 查好傳進來）。
    package func changeGrantScope(
        employeeAccessId: String,
        userId: String,
        permission: String,
        grantScopes: [GrantScope],
        allowedKinds: Set<GrantScopeKind>?
    ) throws {
        // IDENTITY GUARD：同 grantPrivilege，event 的 userId 必須等於本 profile 的 self.userId。
        guard userId == self.userId else {
            throw ContextError<EmployeeAccessError>.userIdMismatch(function: #function, message: "request userId does not match this profile's userId")
        }
        // 只能改直接持有的權限的範圍（範圍化的權限只能直接授予，不會從角色來）。
        guard (self.permissions ?? []).contains(permission) else {
            throw ContextError<EmployeeAccessError>.permissionNotExist(function: #function, message: "permission \(permission) is not directly granted to user")
        }
        guard let allowedKinds else {
            throw ContextError<EmployeeAccessError>.grantScopeNotApplicable(function: #function, message: "permission \(permission) does not take a grant scope")
        }
        let validated = try GrantScopeRules.validated(grantScopes, allowed: allowedKinds, permission: permission)
        guard validated != (self.grantScopes[permission] ?? []) else {
            throw ContextError<EmployeeAccessError>.grantScopeUnchanged(function: #function, message: "grant scope of \(permission) is unchanged")
        }
        try self.apply(event: PrivilegeRevoked(employeeAccessId: self.id, userId: userId, permissions: [permission], occurred: .now))
        try self.apply(event: PrivilegeGranted(
            employeeAccessId: self.id,
            userId: userId,
            permissions: [permission],
            grantScopes: [permission: validated],
            occurred: .now
        ))
    }
}
