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
