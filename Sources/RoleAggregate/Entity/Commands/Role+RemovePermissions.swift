import DDDKit
import Foundation
import IAMContextShared

extension Role {
    package func removePermissions(roleId: String, permissions requestedPermissions: Set<String>) throws {
        // IDENTITY GUARD: event roleId must match this aggregate's id; do not trust request path values.
        guard roleId == self.id else {
            throw DDDError.operationNotAllow(operation: #function, reason: "request roleId does not match this role", userInfos: ["roleId": roleId, "aggregateRootId": self.id])
        }
        let netPermissions = requestedPermissions.intersection(self.permissions ?? [])
        guard !netPermissions.isEmpty else {
            throw ContextError<RoleError>.permissionsUnchanged(function: #function, message: "permissions are unchanged")
        }
        let event = RolePermissionsRemoved(roleId: self.id, permissions: netPermissions, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches RolePermissionsRemoved.
    // State changes belong here, not in removePermissions().
    package func when(event: RolePermissionsRemoved) throws {
        self.permissions = (self.permissions ?? []).subtracting(event.permissions)
    }
}
