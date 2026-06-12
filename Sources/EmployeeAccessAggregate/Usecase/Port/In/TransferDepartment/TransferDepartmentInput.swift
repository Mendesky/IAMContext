import DDDKit
import Foundation
import IAMContextShared
package struct TransferDepartmentInput: UseCaseInput {
    package let employeeAccessId: String
    package let userId: String
    package let newDepartment: String
    package let newJobTitle: String
    package let operatorId: String

    package init(employeeAccessId: String, userId: String, newDepartment: String, newJobTitle: String, operatorId: String) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.newDepartment = newDepartment
        self.newJobTitle = newJobTitle
        self.operatorId = operatorId
    }
}
