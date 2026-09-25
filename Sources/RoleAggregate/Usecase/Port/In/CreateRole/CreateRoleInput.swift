import DDDKit
import Foundation
import IAMContextShared

package struct CreateRoleInput: UseCaseInput {
    package let name: String
    package let description: String?
    package let operatorId: String

    package init(name: String, description: String?, operatorId: String) {
        self.name = name
        self.description = description
        self.operatorId = operatorId
    }
}
