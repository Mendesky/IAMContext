import Foundation
import IAMContextShared

package enum EmployeeAccessError: Error, Equatable {
    case userIdNotExist  // 確認 User ID 存在
    case permissionNotMatch  // 確認使用者身上的權限符合部門、職稱
    case employeeNotActive  // 員工必須在職
    // Added post-/domain-fill (human-authorized 2026-06-03): command-precondition errors beyond bundle invariants.
    case permissionAlreadyExists  // 授予的權限已存在於該用戶
    case permissionNotExist  // 撤銷的權限不存在於該用戶
    case roleAlreadyExists  // 指派的角色已存在於該用戶
    case roleNotExist  // 撤銷的角色不存在於該用戶
    case departmentUnchanged  // 轉調後職稱、部門沒有變化
}

extension ContextError where ErrorType == EmployeeAccessError {
    static func userIdNotExist(function: String = #function, message: String = "") -> Self {
        .init(error: .userIdNotExist, in: .class(EmployeeAccess.self, function: function), message: message)
    }
    static func permissionNotMatch(function: String = #function, message: String = "") -> Self {
        .init(error: .permissionNotMatch, in: .class(EmployeeAccess.self, function: function), message: message)
    }
    static func employeeNotActive(function: String = #function, message: String = "") -> Self {
        .init(error: .employeeNotActive, in: .class(EmployeeAccess.self, function: function), message: message)
    }
    static func permissionAlreadyExists(function: String = #function, message: String = "") -> Self {
        .init(error: .permissionAlreadyExists, in: .class(EmployeeAccess.self, function: function), message: message)
    }
    static func permissionNotExist(function: String = #function, message: String = "") -> Self {
        .init(error: .permissionNotExist, in: .class(EmployeeAccess.self, function: function), message: message)
    }
    static func roleAlreadyExists(function: String = #function, message: String = "") -> Self {
        .init(error: .roleAlreadyExists, in: .class(EmployeeAccess.self, function: function), message: message)
    }
    static func roleNotExist(function: String = #function, message: String = "") -> Self {
        .init(error: .roleNotExist, in: .class(EmployeeAccess.self, function: function), message: message)
    }
    static func departmentUnchanged(function: String = #function, message: String = "") -> Self {
        .init(error: .departmentUnchanged, in: .class(EmployeeAccess.self, function: function), message: message)
    }
}
