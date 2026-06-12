import DDDKit
import Foundation
import IAMContextShared
package struct PromoteUserInput: UseCaseInput {
    package let employeeAccessId: String
    package let userId: String
    package let newJobTitle: String
    package let oldJobTitle: String
    package let operatorId: String

    package init(employeeAccessId: String, userId: String, newJobTitle: String, oldJobTitle: String, operatorId: String) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.newJobTitle = newJobTitle
        self.oldJobTitle = oldJobTitle
        self.operatorId = operatorId
    }
}
