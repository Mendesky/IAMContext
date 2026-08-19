import DDDKit
import Foundation
import IAMContextShared
package struct TransferDepartmentInput: UseCaseInput {
    package let employeeAccessId: String
    package let userId: String
    package let newDepartment: String
    package let newJobTitle: String
    package let newFirm: String?
    package let operatorId: String

    package init(employeeAccessId: String, userId: String, newDepartment: String, newJobTitle: String, operatorId: String, newFirm: String? = nil) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.newDepartment = newDepartment
        self.newJobTitle = newJobTitle
        self.newFirm = newFirm
        self.operatorId = operatorId
    }
}
