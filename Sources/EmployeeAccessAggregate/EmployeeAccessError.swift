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
    // Added post-review (human-authorized 2026-06-12): integrity guards surfaced by code review.
    case userIdMismatch  // 請求帶的 userId 與該 profile（由 employeeAccessId 載入）的 userId 不一致
    case profileAlreadyExists  // 同一 employeeAccessId 已有 profile（避免重複建立 → 事件流出現兩個 createdEvent）
    // Added (human-authorized 2026-08-05): create command must carry a non-blank firm.
    case firmRequired  // 建立 profile 時 firm 為 nil 或空字串
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
    static func userIdMismatch(function: String = #function, message: String = "") -> Self {
        .init(error: .userIdMismatch, in: .class(EmployeeAccess.self, function: function), message: message)
    }
    static func profileAlreadyExists(function: String = #function, message: String = "") -> Self {
        .init(error: .profileAlreadyExists, in: .class(EmployeeAccess.self, function: function), message: message)
    }
    static func firmRequired(function: String = #function, message: String = "") -> Self {
        .init(error: .firmRequired, in: .class(EmployeeAccess.self, function: function), message: message)
    }
}
