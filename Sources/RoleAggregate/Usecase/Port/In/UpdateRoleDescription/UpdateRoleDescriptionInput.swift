import DDDKit
import Foundation
import IAMContextShared

package struct UpdateRoleDescriptionInput: UseCaseInput {
    package let roleId: String
    package let newDescription: String?
    package let operatorId: String

    package init(roleId: String, newDescription: String?, operatorId: String) {
        self.roleId = roleId
        self.newDescription = newDescription
        self.operatorId = operatorId
    }
}
