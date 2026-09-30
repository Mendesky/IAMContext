import DDDKit
import Foundation
import IAMContextShared

package struct DeleteRoleInput: UseCaseInput {
    package let roleId: String
    package let operatorId: String

    package init(roleId: String, operatorId: String) {
        self.roleId = roleId
        self.operatorId = operatorId
    }
}
