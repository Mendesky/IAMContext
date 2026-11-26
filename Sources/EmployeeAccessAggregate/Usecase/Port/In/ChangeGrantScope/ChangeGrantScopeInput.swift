import DDDKit
import Foundation
import IAMContextShared
package struct ChangeGrantScopeInput: UseCaseInput {
    package let employeeAccessId: String
    package let userId: String
    package let permission: String
    package let grantScopes: [GrantScope]
    package let operatorId: String

    package init(employeeAccessId: String, userId: String, permission: String, grantScopes: [GrantScope], operatorId: String) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.permission = permission
        self.grantScopes = grantScopes
        self.operatorId = operatorId
    }
}
