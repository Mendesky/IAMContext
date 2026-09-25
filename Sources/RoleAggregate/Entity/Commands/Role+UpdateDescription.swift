import DDDKit
import Foundation
import IAMContextShared

extension Role {
    package func updateDescription(roleId: String, newDescription: String?) throws {
        guard newDescription != self.description else {
            throw ContextError<RoleError>.descriptionUnchanged(function: #function, message: "role description is unchanged")
        }
        // IDENTITY GUARD: event roleId must match this aggregate's id; do not trust request path values.
        guard roleId == self.id else {
            throw DDDError.operationNotAllow(operation: #function, reason: "request roleId does not match this role", userInfos: ["roleId": roleId, "aggregateRootId": self.id])
        }
        let event = RoleDescriptionUpdated(roleId: self.id, newDescription: newDescription, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches RoleDescriptionUpdated.
    // State changes belong here, not in updateDescription().
    package func when(event: RoleDescriptionUpdated) throws {
        self.description = event.newDescription
    }
}
