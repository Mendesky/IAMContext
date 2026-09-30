import DDDKit
import Foundation
import IAMContextShared

extension Role {
    package func addPermissions(roleId: String, permissions requestedPermissions: Set<String>) throws {
        // IDENTITY GUARD: event roleId must match this aggregate's id; do not trust request path values.
        guard roleId == self.id else {
            throw DDDError.operationNotAllow(operation: #function, reason: "request roleId does not match this role", userInfos: ["roleId": roleId, "aggregateRootId": self.id])
        }
        let netPermissions = requestedPermissions.subtracting(self.permissions ?? [])
        guard !netPermissions.isEmpty else {
            throw ContextError<RoleError>.permissionsUnchanged(function: #function, message: "permissions are unchanged")
        }
        let event = RolePermissionsAdded(roleId: self.id, permissions: netPermissions, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches RolePermissionsAdded.
    // State changes belong here, not in addPermissions().
    package func when(event: RolePermissionsAdded) throws {
        self.permissions = (self.permissions ?? []).union(event.permissions)
    }
}
