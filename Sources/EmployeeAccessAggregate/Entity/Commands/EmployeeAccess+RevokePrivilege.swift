import DDDKit
import Foundation
import IAMContextShared
extension EmployeeAccess {
    package func revokePrivilege(employeeAccessId: String, userId: String, permissions: [String]) throws {
        // PRECONDITION (from bundle): permissions all exist in user.permissions
        // domain-fill: precondition — 要撤銷的 permission 任一不存在於 self.permissions → permissionNotExist
        if let missing = permissions.first(where: { !(self.permissions ?? []).contains($0) }) {
            throw ContextError<EmployeeAccessError>.permissionNotExist(function: #function, message: "permission \(missing) does not exist for user")
        }
        // IDENTITY GUARD (code review 2026-06-12): event 的 userId 必須等於本 profile 的 self.userId，不可信任請求值。
        // 詳見 EmployeeAccess+GrantPrivilege.swift 同名守門的完整說明。
        guard userId == self.userId else {
            throw ContextError<EmployeeAccessError>.userIdMismatch(function: #function, message: "request userId does not match this profile's userId")
        }
        let event = PrivilegeRevoked(employeeAccessId: self.id, userId: userId, permissions: permissions, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches PrivilegeRevoked.
    // ⚠️ this is the file where state actually changes during replay; do NOT mutate in revokePrivilege().
    package func when(event: PrivilegeRevoked) throws {
        // PrivilegeRevoked state transition is not strict-safe (empty payload / collection / type-mismatch / new-old rename / nested).
        // domain-fill: 差集移除 event.permissions（nil 視為空集合）
        self.permissions = (self.permissions ?? []).subtracting(event.permissions)
    }
}
