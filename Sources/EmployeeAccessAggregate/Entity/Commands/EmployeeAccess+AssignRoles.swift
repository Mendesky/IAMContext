import DDDKit
import Foundation
import IAMContextShared
extension EmployeeAccess {
    package func assignRoles(employeeAccessId: String, userId: String, roles: [String]) throws {
        // PRECONDITION (from bundle): roles not already in user.roles
        // domain-fill: precondition — 要指派的 role 任一已存在於 self.roles → roleAlreadyExists
        guard !roles.contains(where: { (self.roles ?? []).contains($0) }) else {
            throw ContextError<EmployeeAccessError>.roleAlreadyExists(function: #function, message: "role already assigned to user")
        }
        // IDENTITY GUARD (code review 2026-06-12): event 的 userId 必須等於本 profile 的 self.userId，不可信任請求值。
        // 詳見 EmployeeAccess+GrantPrivilege.swift 同名守門的完整說明。
        guard userId == self.userId else {
            throw ContextError<EmployeeAccessError>.userIdMismatch(function: #function, message: "request userId does not match this profile's userId")
        }
        let event = RolesAssigned(employeeAccessId: self.id, userId: userId, roles: roles, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches RolesAssigned.
    // ⚠️ this is the file where state actually changes during replay; do NOT mutate in assignRoles().
    package func when(event: RolesAssigned) throws {
        // RolesAssigned state transition is not strict-safe (empty payload / collection / type-mismatch / new-old rename / nested).
        // domain-fill: 聯集加入 event.roles（nil 視為空集合）
        self.roles = (self.roles ?? []).union(event.roles)
    }
}
