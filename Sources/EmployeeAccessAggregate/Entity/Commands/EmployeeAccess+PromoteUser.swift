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
