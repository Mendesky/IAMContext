import DDDKit
import Foundation
import IAMContextShared

package struct RenameRoleInput: UseCaseInput {
    package let roleId: String
    package let newName: String
    package let operatorId: String

    package init(roleId: String, newName: String, operatorId: String) {
        self.roleId = roleId
        self.newName = newName
        self.operatorId = operatorId
    }
}
