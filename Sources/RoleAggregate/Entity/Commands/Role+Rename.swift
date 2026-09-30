import DDDKit
import Foundation
import IAMContextShared

extension Role {
    package func rename(roleId: String, newName: String) throws {
        guard newName != self.name else {
            throw ContextError<RoleError>.roleNameUnchanged(function: #function, message: "role name is unchanged")
        }
        // IDENTITY GUARD: event roleId must match this aggregate's id; do not trust request path values.
        guard roleId == self.id else {
            throw DDDError.operationNotAllow(operation: #function, reason: "request roleId does not match this role", userInfos: ["roleId": roleId, "aggregateRootId": self.id])
        }
        let event = RoleRenamed(roleId: self.id, newName: newName, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches RoleRenamed.
    // State changes belong here, not in rename().
    package func when(event: RoleRenamed) throws {
        self.name = event.newName
    }
}
