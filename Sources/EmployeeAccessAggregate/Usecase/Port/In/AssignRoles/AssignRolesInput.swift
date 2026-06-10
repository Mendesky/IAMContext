import DDDKit
import Foundation
import IAMContextShared
package struct AssignRolesInput: UseCaseInput {
    package let employeeAccessId: String
    package let userId: String
    package let roles: [String]
    package let operatorId: String

    package init(employeeAccessId: String, userId: String, roles: [String], operatorId: String) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.roles = roles
        self.operatorId = operatorId
    }
}
