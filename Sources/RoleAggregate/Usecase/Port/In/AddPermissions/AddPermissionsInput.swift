import DDDKit
import Foundation
import IAMContextShared

package struct AddPermissionsInput: UseCaseInput {
    package let roleId: String
    package let permissions: [String]
    package let operatorId: String

    package init(roleId: String, permissions: [String], operatorId: String) {
        self.roleId = roleId
        self.permissions = permissions
        self.operatorId = operatorId
    }
}
