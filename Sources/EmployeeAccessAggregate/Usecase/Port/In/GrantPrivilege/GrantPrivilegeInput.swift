import DDDKit
import Foundation
import IAMContextShared
package struct GrantPrivilegeInput: UseCaseInput {
    package let employeeAccessId: String
    package let userId: String
    package let permissions: [String]
    /// 範圍化權限的授權範圍（權限 → 範圍清單）；不是範圍化的權限不能出現在這裡。
    package let grantScopes: [String: [GrantScope]]
    package let operatorId: String

    package init(employeeAccessId: String, userId: String, permissions: [String], grantScopes: [String: [GrantScope]] = [:], operatorId: String) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.permissions = permissions
        self.grantScopes = grantScopes
        self.operatorId = operatorId
    }
}
