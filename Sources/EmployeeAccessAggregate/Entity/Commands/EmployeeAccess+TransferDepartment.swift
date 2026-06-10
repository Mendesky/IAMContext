import DDDKit
import Foundation
import IAMContextShared
extension EmployeeAccess {
    package func transferDepartment(employeeAccessId: String, userId: String, newDepartment: String, newJobTitle: String) throws {
        // PRECONDITION (from bundle): (newDepartment, newJobTitle) != (current department, jobTitle)
        // domain-fill: precondition — 新舊 (department, jobTitle) 完全相同 → departmentUnchanged
        guard !(newDepartment == self.department && newJobTitle == self.jobTitle) else {
            throw ContextError<EmployeeAccessError>.departmentUnchanged(function: #function, message: "職稱、部門沒有變化")
        }
        let event = DepartmentTransferred(employeeAccessId: self.id, userId: userId, newDepartment: newDepartment, newJobTitle: newJobTitle, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches DepartmentTransferred.
    // ⚠️ this is the file where state actually changes during replay; do NOT mutate in transferDepartment().
    package func when(event: DepartmentTransferred) throws {
        // DepartmentTransferred state transition is not strict-safe (empty payload / collection / type-mismatch / new-old rename / nested).
        // domain-fill: 轉調 → 更新部門與職稱
        self.department = event.newDepartment
        self.jobTitle = event.newJobTitle
    }
}
