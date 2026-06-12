import DDDKit
import Foundation
import IAMContextShared
extension EmployeeAccess {
    package func grantPrivilege(employeeAccessId: String, userId: String, permissions: [String]) throws {
        // PRECONDITION (from bundle): permissions not already in user.permissions
        // domain-fill: precondition — 要授予的 permission 任一已存在於 self.permissions → permissionAlreadyExists
        guard !permissions.contains(where: { (self.permissions ?? []).contains($0) }) else {
            throw ContextError<EmployeeAccessError>.permissionAlreadyExists(function: #function, message: "permission already granted to user")
        }
        // IDENTITY GUARD (code review 2026-06-12): aggregate 由 employeeAccessId 載入，event 的 userId 必須是這個
        // profile 真正的 userId（self.userId），不可信任請求帶來的 userId。否則打錯/填別人 userId 會把權限事件灌進別人
        // 的身分，污染 GetPermissions 投影（以 userId 分區）與任何下游稽核。self.userId 建檔後不可變，故一律比對相等。
        guard userId == self.userId else {
            throw ContextError<EmployeeAccessError>.userIdMismatch(function: #function, message: "request userId does not match this profile's userId")
        }
        let event = PrivilegeGranted(employeeAccessId: self.id, userId: userId, permissions: permissions, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches PrivilegeGranted.
    // ⚠️ this is the file where state actually changes during replay; do NOT mutate in grantPrivilege().
    package func when(event: PrivilegeGranted) throws {
        // PrivilegeGranted state transition is not strict-safe (empty payload / collection / type-mismatch / new-old rename / nested).
        // domain-fill: 聯集加入 event.permissions（nil 視為空集合）
        self.permissions = (self.permissions ?? []).union(event.permissions)
    }
}
