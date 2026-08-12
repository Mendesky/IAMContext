import Foundation
import IAMContextShared

package struct TransferDepartmentApplicationServiceInput {
    package let employeeAccessId: String
    package let userId: String
    package let newDepartment: String
    package let newJobTitle: String
    package let newFirm: String?
    package let operatorId: String

    package init(
        employeeAccessId: String,
        userId: String,
        newDepartment: String,
        newJobTitle: String,
        operatorId: String,
        newFirm: String? = nil
    ) {
        self.employeeAccessId = employeeAccessId
        self.userId = userId
        self.newDepartment = newDepartment
        self.newJobTitle = newJobTitle
        self.newFirm = newFirm
        self.operatorId = operatorId
    }
}

package struct TransferDepartmentApplicationServiceOutput {
    package let employeeAccessId: String
}

package struct TransferDepartmentApplicationService: ApplicationService {
    package typealias Input = TransferDepartmentApplicationServiceInput
    package typealias Output = TransferDepartmentApplicationServiceOutput

    private let repository: EmployeeAccessRepository

    package init(repository: EmployeeAccessRepository) {
        self.repository = repository
    }

    package func execute(input: Input) async throws -> Output {
        let service = TransferDepartmentService(repository: repository)
        _ = try await service.execute(input: .init(
            employeeAccessId: input.employeeAccessId,
            userId: input.userId,
            newDepartment: input.newDepartment,
            newJobTitle: input.newJobTitle,
            operatorId: input.operatorId,
            newFirm: input.newFirm
        ))
        return .init(employeeAccessId: input.employeeAccessId)
    }
}
