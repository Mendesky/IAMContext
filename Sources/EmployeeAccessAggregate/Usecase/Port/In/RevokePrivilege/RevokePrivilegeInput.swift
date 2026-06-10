import DDDKit
import Foundation
import IAMContextShared
package struct RevokePrivilegeInput: UseCaseInput {
    package let employeeAccessId: String
    package let userId: String
    package let permissions: [String]
    package let operatorId: String

    package init(employeeAccessId: String, userId: String, permissions: [String], operatorId: String) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.permissions = permissions
        self.operatorId = operatorId
    }
}
