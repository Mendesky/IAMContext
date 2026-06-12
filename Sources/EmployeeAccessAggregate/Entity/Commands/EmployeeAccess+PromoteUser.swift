import DDDKit
import Foundation
import IAMContextShared
extension EmployeeAccess {
    package func promoteUser(employeeAccessId: String, userId: String, newJobTitle: String, oldJobTitle: String) throws {
        // PRECONDITION (from bundle): status == Active
        // domain-fill: precondition — status 必須為 .Active，否則 employeeNotActive
        guard status == .Active else {
            throw ContextError<EmployeeAccessError>.employeeNotActive(function: #function, message: "employee status must be Active to promote")
        }
        // IDENTITY GUARD (code review 2026-06-12): event 的 userId 必須等於本 profile 的 self.userId，不可信任請求值。
        // 詳見 EmployeeAccess+GrantPrivilege.swift 同名守門的完整說明。
        guard userId == self.userId else {
            throw ContextError<EmployeeAccessError>.userIdMismatch(function: #function, message: "request userId does not match this profile's userId")
        }
        let event = UserPromoted(employeeAccessId: self.id, userId: userId, newJobTitle: newJobTitle, oldJobTitle: oldJobTitle, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches UserPromoted.
    // ⚠️ this is the file where state actually changes during replay; do NOT mutate in promoteUser().
    package func when(event: UserPromoted) throws {
        // UserPromoted state transition is not strict-safe (empty payload / collection / type-mismatch / new-old rename / nested).
        // domain-fill: 升遷 → 更新職稱為 newJobTitle（oldJobTitle 僅 audit，不套用）
        self.jobTitle = event.newJobTitle
    }
}
