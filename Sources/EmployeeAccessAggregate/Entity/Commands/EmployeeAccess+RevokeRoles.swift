import DDDKit
import Foundation
import IAMContextShared
extension EmployeeAccess {
    package func revokeRoles(employeeAccessId: String, userId: String, roles: [String]) throws {
        // PRECONDITION (from bundle): roles all exist in user.roles
        // domain-fill: precondition — 要撤銷的 role 任一不存在於 self.roles → roleNotExist
        if let missing = roles.first(where: { !(self.roles ?? []).contains($0) }) {
            throw ContextError<EmployeeAccessError>.roleNotExist(function: #function, message: "role \(missing) does not exist for user")
        }
        // IDENTITY GUARD (code review 2026-06-12): event 的 userId 必須等於本 profile 的 self.userId，不可信任請求值。
        // 詳見 EmployeeAccess+GrantPrivilege.swift 同名守門的完整說明。
        guard userId == self.userId else {
            throw ContextError<EmployeeAccessError>.userIdMismatch(function: #function, message: "request userId does not match this profile's userId")
        }
        let event = RolesRevoked(employeeAccessId: self.id, userId: userId, roles: roles, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches RolesRevoked.
    // ⚠️ this is the file where state actually changes during replay; do NOT mutate in revokeRoles().
    package func when(event: RolesRevoked) throws {
        // RolesRevoked state transition is not strict-safe (empty payload / collection / type-mismatch / new-old rename / nested).
        // domain-fill: 差集移除 event.roles（nil 視為空集合）
        self.roles = (self.roles ?? []).subtracting(event.roles)
    }
}
