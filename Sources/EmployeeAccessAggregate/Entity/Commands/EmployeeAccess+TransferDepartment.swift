import DDDKit
import Foundation
import IAMContextShared
extension EmployeeAccess {
    package func transferDepartment(employeeAccessId: String, userId: String, newDepartment: String, newJobTitle: String, newFirm: String? = nil) throws {
        // PRECONDITION: department、jobTitle、firm 三者全部未變 → departmentUnchanged
        // 只要有任一欄位不同（含只改 firm）就放行，允許 firm-only 異動。
        let firmUnchanged = newFirm == nil || newFirm == self.firm
        guard !(newDepartment == self.department && newJobTitle == self.jobTitle && firmUnchanged) else {
            throw ContextError<EmployeeAccessError>.departmentUnchanged(function: #function, message: "職稱、部門、所別皆沒有變化")
        }
        // IDENTITY GUARD (code review 2026-06-12): event 的 userId 必須等於本 profile 的 self.userId，不可信任請求值。
        // 詳見 EmployeeAccess+GrantPrivilege.swift 同名守門的完整說明。
        guard userId == self.userId else {
            throw ContextError<EmployeeAccessError>.userIdMismatch(function: #function, message: "request userId does not match this profile's userId")
        }
        let event = DepartmentTransferred(employeeAccessId: self.id, userId: userId, newDepartment: newDepartment, newJobTitle: newJobTitle, newFirm: newFirm, occurred: .now)
        try self.apply(event: event)
    }

    // Called by the plugin-generated when(happened:) dispatch when event matches DepartmentTransferred.
    // ⚠️ this is the file where state actually changes during replay; do NOT mutate in transferDepartment().
    package func when(event: DepartmentTransferred) throws {
        // DepartmentTransferred state transition is not strict-safe (empty payload / collection / type-mismatch / new-old rename / nested).
        // domain-fill: 轉調 → 更新部門與職稱；newFirm 若有帶入則更新所別
        self.department = event.newDepartment
        self.jobTitle = event.newJobTitle
        if let newFirm = event.newFirm {
            self.firm = newFirm
        }
    }
}
