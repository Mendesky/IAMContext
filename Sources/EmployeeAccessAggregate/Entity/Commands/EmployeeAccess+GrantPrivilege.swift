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
