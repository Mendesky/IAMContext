import DDDKit
import Foundation
import IAMContextShared
package struct CreateUserAccessProfileInput: UseCaseInput {
    package let employeeAccessId: String
    package let userId: String
    package let department: String
    package let jobTitle: String
    package let operatorId: String

    package init(employeeAccessId: String, userId: String, department: String, jobTitle: String, operatorId: String) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.department = department
        self.jobTitle = jobTitle
        self.operatorId = operatorId
    }
}
